// dush_native.cpp - native exact disk usage tool.
// Reconstructed to the final working version (packed single-file index.bin per root,
// parallel two-phase index builder, auto-index queries that always print the full
// sorted table, background warm-up, stale/age refresh, watcher-safe publish).

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winioctl.h>
#include <shlobj.h>
#include <time.h>
#include <pthread_time.h>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// Statically linked Everything SDK, patched to talk only to the isolated DUSH
// instance. The live NTFS index is the drive-root fast path; the native scanner
// below remains the correctness fallback when that index is unavailable.
#define EVERYTHINGUSERAPI
extern "C" {
#include "../tools/Everything/SDK/include/Everything.h"
}

// The bundled winlibs libstdc++ 16 references the mingw-w64 time64 symbols
// (clock_gettime64 / nanosleep64) that this toolchain's winpthreads runtime
// does not export. Provide thin forwarders to the 32-bit-time equivalents,
// which are ABI-identical on 64-bit Windows.
extern "C" int clock_gettime64(clockid_t clock_id, struct timespec *tp) {
    return clock_gettime(clock_id, tp);
}
extern "C" int nanosleep64(const struct timespec *rqtp, struct timespec *rmtp) {
    return nanosleep(rqtp, rmtp);
}

struct Counters {
    unsigned long long bytes = 0;
    unsigned long long files = 0;
    unsigned long long dirs = 0;
    unsigned long long inaccessible = 0;
    unsigned long long reparse_dirs = 0;
};

struct IndexBuildResult : Counters {
};

struct Item {
    std::wstring path;
    unsigned int attrs = 0;
    bool is_dir = false;
    bool is_reparse = false;
    unsigned long long bytes = 0;
    unsigned long long files = 0;
    unsigned long long dirs = 0;
    unsigned long long inaccessible = 0;
    unsigned long long reparse_dirs = 0;
};

static std::wstring join_path(const std::wstring &base, const std::wstring &name) {
    if (base.empty()) return name;
    if (base.back() == L'\\') return base + name;
    return base + L"\\" + name;
}

// Long-path form (\\?\-prefixed) so deep trees scan without MAX_PATH limits.
static std::wstring long_path(const std::wstring &p) {
    if (p.size() >= 4 && p.compare(0, 4, L"\\\\?\\") == 0) return p;
    if (p.size() >= 2 && p[0] == L'\\' && p[1] == L'\\') return L"\\\\?\\UNC\\" + p.substr(2);
    return L"\\\\?\\" + p;
}

static std::wstring display_path(const std::wstring &p) {
    if (p.size() >= 4 && p.compare(0, 4, L"\\\\?\\") == 0) {
        std::wstring r = p.substr(4);
        if (r.size() >= 4 && r.compare(0, 4, L"UNC\\") == 0) return L"\\\\" + r.substr(4);
        return r;
    }
    return p;
}

static bool item_display_less(const Item &a, const Item &b) {
    if (a.is_dir != b.is_dir) return a.is_dir > b.is_dir;
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return _wcsicmp(a.path.c_str(), b.path.c_str()) < 0;
}

// Lowercased, trailing-backslash-stripped display form; used as cache keys and
// for the root hashes that name per-root cache directories.
static std::wstring normalized_key(const std::wstring &path) {
    std::wstring s = display_path(path);
    if (s.size() > 1 && s.back() == L'\\') s.pop_back();
    for (auto &c : s) {
        if (c >= L'A' && c <= L'Z') c += 32;
    }
    return s;
}

static unsigned long long fnv1a64(const std::wstring &s) {
    unsigned long long h = 14695981039346656037ull;
    for (wchar_t c : s) {
        unsigned char lo = static_cast<unsigned char>(c);
        unsigned char hi = static_cast<unsigned char>(c >> 8);
        h ^= lo;
        h *= 1099511628211ull;
        h ^= hi;
        h *= 1099511628211ull;
    }
    return h;
}

static std::wstring hex64(unsigned long long v) {
    wchar_t buf[17];
    swprintf(buf, 17, L"%016llx", v);
    return std::wstring(buf);
}

static std::wstring leaf_name(const std::wstring &p) {
    size_t pos = p.find_last_of(L'\\');
    return pos == std::wstring::npos ? p : p.substr(pos + 1);
}

static bool is_fast_index_drive_root(const std::wstring &root_display) {
    if (root_display.size() != 2 || root_display[1] != L':') return false;
    const wchar_t drive = static_cast<wchar_t>(towupper(root_display[0]));
    return drive == L'C' || drive == L'F';
}

// Query the private, continuously monitored NTFS index. Only two tiny IPC
// replies are needed regardless of tree complexity: direct children with their
// recursive sizes, then one capped path query whose reply header contains the
// complete file/folder counts. The patched SDK bounds every IPC wait; failure
// returns false and the ordinary native enumerator takes over.
static bool query_fast_drive_index(const std::wstring &root_display,
                                   std::vector<Item> &items) {
    if (!is_fast_index_drive_root(root_display)) return false;
    if (!FindWindowW(L"EVERYTHING_TASKBAR_NOTIFICATION_(DUSH)", nullptr)) return false;
    if (!Everything_IsDBLoaded()) return false;

    const std::wstring drive_root = root_display + L"\\";
    const std::wstring parent_query = L"parent:" + drive_root;

    Everything_Reset();
    Everything_SetMatchPath(FALSE);
    Everything_SetSearchW(parent_query.c_str());
    Everything_SetMax(0xffffffffu);
    Everything_SetSort(EVERYTHING_SORT_NAME_ASCENDING);
    Everything_SetRequestFlags(EVERYTHING_REQUEST_FILE_NAME |
                               EVERYTHING_REQUEST_SIZE |
                               EVERYTHING_REQUEST_ATTRIBUTES);
    if (!Everything_QueryW(TRUE)) {
        Everything_Reset();
        return false;
    }

    const DWORD direct_count = Everything_GetNumResults();
    std::vector<Item> direct;
    direct.reserve(direct_count);
    for (DWORD i = 0; i < direct_count; ++i) {
        const wchar_t *name = Everything_GetResultFileNameW(i);
        if (!name || !*name) {
            Everything_Reset();
            return false;
        }
        LARGE_INTEGER size{};
        if (!Everything_GetResultSize(i, &size) || size.QuadPart < 0) {
            Everything_Reset();
            return false;
        }
        Item item;
        item.path = join_path(root_display, name);
        item.attrs = Everything_GetResultAttributes(i);
        item.is_dir = Everything_IsFolderResult(i) != FALSE;
        item.is_reparse = (item.attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
        item.bytes = static_cast<unsigned long long>(size.QuadPart);
        direct.push_back(std::move(item));
    }

    // Match the full path but cap transferred rows at one: the result header
    // still reports separate totals for all matching files and folders.
    Everything_Reset();
    Everything_SetMatchPath(TRUE);
    Everything_SetSearchW(drive_root.c_str());
    Everything_SetMax(1);
    Everything_SetSort(EVERYTHING_SORT_NAME_ASCENDING);
    // Keep the SDK's v1 reply for this count-only query: that header contains
    // separate total-file and total-folder counters, while the v2 header only
    // exposes their combined total.
    Everything_SetRequestFlags(EVERYTHING_REQUEST_PATH |
                               EVERYTHING_REQUEST_FILE_NAME);
    if (!Everything_QueryW(TRUE)) {
        Everything_Reset();
        return false;
    }
    const unsigned long long file_count = Everything_GetTotFileResults();
    const unsigned long long folder_count = Everything_GetTotFolderResults();
    Everything_Reset();

// print_results aggregates these counters but does not display them per row.
    // Store the already-computed totals on one row to preserve its shared output
    // path without manufacturing recursive per-child counts.
    if (direct.empty()) {
        return false;
    }
    direct.front().files = file_count;
    direct.front().dirs = folder_count;
    items = std::move(direct);
    return true;
}

static unsigned long long file_size(const WIN32_FIND_DATAW &fd) {
    return (static_cast<unsigned long long>(fd.nFileSizeHigh) << 32) | fd.nFileSizeLow;
}

static bool write_all(HANDLE h, const void *data, DWORD bytes) {
    const unsigned char *p = static_cast<const unsigned char *>(data);
    while (bytes) {
        DWORD n = 0;
        if (!WriteFile(h, p, bytes, &n, nullptr) || n == 0) return false;
        p += n;
        bytes -= n;
    }
    return true;
}

static bool read_exact(HANDLE h, void *data, DWORD bytes) {
    unsigned char *p = static_cast<unsigned char *>(data);
    while (bytes) {
        DWORD n = 0;
        if (!ReadFile(h, p, bytes, &n, nullptr) || n == 0) return false;
        p += n;
        bytes -= n;
    }
    return true;
}

static bool read_wstr(HANDLE h, std::wstring &out) {
    unsigned int n = 0;
    if (!read_exact(h, &n, sizeof(n))) return false;
    if (n > 1000000u) return false;
    out.resize(n);
    if (n && !read_exact(h, &out[0], static_cast<DWORD>(n * sizeof(wchar_t)))) return false;
    return true;
}

static bool read_u8(HANDLE h, unsigned char &v) {
    return read_exact(h, &v, 1);
}

static bool read_u32(HANDLE h, unsigned int &v) {
    return read_exact(h, &v, sizeof(v));
}

static bool read_u64(HANDLE h, unsigned long long &v) {
    return read_exact(h, &v, sizeof(v));
}

static bool ensure_dir(const std::wstring &path) {
    if (path.empty()) return false;
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return true;
    size_t start = (path.size() >= 2 && path[0] == L'\\' && path[1] == L'\\') ? 2 : 0;
    size_t pos = path.find(L'\\', start);
    while (pos != std::wstring::npos) {
        std::wstring sub = path.substr(0, pos);
        if (!sub.empty() && GetFileAttributesW(sub.c_str()) == INVALID_FILE_ATTRIBUTES) {
            CreateDirectoryW(sub.c_str(), nullptr);
        }
        pos = path.find(L'\\', pos + 1);
    }
    CreateDirectoryW(path.c_str(), nullptr);
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

static std::wstring g_index_output_dir;

static std::wstring exe_dir() {
    std::vector<wchar_t> buf(32768);
    DWORD got = GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
    if (!got) return L"";
    std::wstring p(buf.data(), got);
    size_t pos = p.find_last_of(L'\\');
    return pos == std::wstring::npos ? p : p.substr(0, pos);
}

// Package-local cache: the build target writes into g_index_output_dir (a temp
// dir that is atomically renamed into place); normal queries use exe_dir()\cache.
static std::wstring index_dir() {
    if (!g_index_output_dir.empty()) return g_index_output_dir;
    // Keep the packed index + freshness markers on the OS drive (C:), separate from
    // the scanned volume. Writing the cache then can never advance the scanned
    // volume's USN journal, so the instant-repeat freshness proof stays valid for
    // scans of other volumes (e.g. the F: data drive). Falls back to the exe's own
    // folder when %LOCALAPPDATA% is unavailable.
    wchar_t buf[32768];
    DWORD got = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, 32768);
    if (got && got < 32768) {
        std::wstring cand = join_path(std::wstring(buf, got), L"dush\\cache");
        if (GetFileAttributesW(cand.c_str()) != INVALID_FILE_ATTRIBUTES || ensure_dir(cand)) {
            return cand;
        }
    }
    return join_path(exe_dir(), L"cache");
}

static std::wstring index_roots_dir() {
    return join_path(index_dir(), L"roots");
}

static std::wstring index_dir_for_root(const std::wstring &root) {
    return join_path(index_roots_dir(), hex64(fnv1a64(normalized_key(root))));
}

static std::wstring index_complete_file(const std::wstring &dir = L"") {
    std::wstring base = dir.empty() ? index_dir() : dir;
    return join_path(base, L"complete.txt");
}

static std::wstring index_pack_file(const std::wstring &dir) {
    return join_path(dir, L"index.bin");
}

static bool remove_tree(const std::wstring &path) {
    std::wstring pattern = join_path(path, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd,
                                FindExSearchNameMatch, nullptr, 0);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
            std::wstring full = join_path(path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                remove_tree(full);
            } else {
                DeleteFileW(full.c_str());
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return RemoveDirectoryW(path.c_str()) != 0;
}

static bool read_small_text_file(const std::wstring &file, std::wstring &out) {
    out.clear();
    HANDLE h = CreateFileW(file.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(h, &size) || size.QuadPart <= 0 || size.QuadPart > 65536 ||
        (size.QuadPart % sizeof(wchar_t)) != 0) {
        CloseHandle(h);
        return false;
    }
    std::vector<wchar_t> text(static_cast<size_t>(size.QuadPart / sizeof(wchar_t)) + 1, L'\0');
    DWORD got = 0;
    bool ok = ReadFile(h, text.data(), static_cast<DWORD>(size.QuadPart), &got, nullptr) &&
              got == static_cast<DWORD>(size.QuadPart);
    CloseHandle(h);
    if (!ok) return false;
    out.assign(text.data(), got / sizeof(wchar_t));
    return true;
}

// NTFS change-journal watermark so cached snapshots can be proven fresh (or
// stale) against the actual volume in one cheap IOCTL. Query is read-only;
// capture creates the journal first when it is not active and we have access.
static bool query_volume_usn(const std::wstring &root, unsigned long long &journal_id,
                             unsigned long long &next_usn) {
    journal_id = 0;
    next_usn = 0;
    if (root.size() < 2 || root[1] != L':') return false;
    std::wstring vol_path = L"\\\\.\\" + root.substr(0, 2);
    HANDLE h = CreateFileW(vol_path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    USN_JOURNAL_DATA journal = {};
    DWORD ret = 0;
    BOOL ok = DeviceIoControl(h, FSCTL_QUERY_USN_JOURNAL, nullptr, 0,
                              &journal, sizeof(journal), &ret, nullptr);
    CloseHandle(h);
    if (!ok) return false;
    journal_id = journal.UsnJournalID;
    next_usn = static_cast<unsigned long long>(journal.NextUsn);
    return journal_id != 0;
}

static bool capture_volume_usn(const std::wstring &root, unsigned long long &journal_id,
                               unsigned long long &next_usn) {
    journal_id = 0;
    next_usn = 0;
    if (query_volume_usn(root, journal_id, next_usn)) return true;
    if (root.size() < 2 || root[1] != L':') return false;
    std::wstring vol_path = L"\\\\.\\" + root.substr(0, 2);
    HANDLE h = CreateFileW(vol_path.c_str(), GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    CREATE_USN_JOURNAL_DATA create = {};
    create.MaximumSize = 128ull * 1024 * 1024;
    create.AllocationDelta = 16ull * 1024 * 1024;
    DWORD ret = 0;
    BOOL ok = DeviceIoControl(h, FSCTL_CREATE_USN_JOURNAL, &create, sizeof(create),
                              nullptr, 0, &ret, nullptr);
    CloseHandle(h);
    if (!ok) return false;
    return query_volume_usn(root, journal_id, next_usn);
}

static bool write_complete_marker(const std::wstring &root, const IndexBuildResult &result, bool watched) {
    std::wstring file = index_complete_file();
    HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    unsigned long long journal_id = 0, next_usn = 0;
    bool have_usn = capture_volume_usn(root, journal_id, next_usn);
    wchar_t text[1024];
    int n = swprintf(text, 1024,
                     L"DUSH_INDEX_COMPLETE\nmode=%ls\nroot=%ls\nbytes=%llu\nfiles=%llu\ndirs=%llu\npid=%lu\nbuilt=%llu\nusn_valid=%d\nusn_journal=%llu\nusn_next=%llu\n",
                     watched ? L"watch" : L"snapshot",
                     normalized_key(root).c_str(), result.bytes, result.files, result.dirs,
                     GetCurrentProcessId(), static_cast<unsigned long long>(time(nullptr)),
                     have_usn ? 1 : 0, journal_id, next_usn);
    bool ok = n > 0 && write_all(h, text, static_cast<DWORD>(n * sizeof(wchar_t)));
    CloseHandle(h);
    return ok;
}

static bool marker_value(const std::wstring &marker, const wchar_t *name, std::wstring &value) {
    std::wstring prefix = std::wstring(name) + L"=";
    size_t start = marker.find(prefix);
    if (start == std::wstring::npos) return false;
    if (start != 0 && marker[start - 1] != L'\n') return false;
    start += prefix.size();
    size_t end = marker.find(L"\n", start);
    value = marker.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
    return true;
}

static bool read_complete_marker(const std::wstring &dir, bool &watched, std::wstring &root,
                                 unsigned long long &built_seconds) {
    watched = false;
    root.clear();
    built_seconds = 0;
    std::wstring marker;
    if (!read_small_text_file(index_complete_file(dir), marker)) return false;
    if (marker.find(L"DUSH_INDEX_COMPLETE\n") != 0) return false;
    std::wstring mode;
    marker_value(marker, L"mode", mode);
    watched = mode == L"watch";
    std::wstring built;
    if (marker_value(marker, L"built", built)) built_seconds = wcstoull(built.c_str(), nullptr, 10);
    return marker_value(marker, L"root", root) && !root.empty();
}

static bool read_usn_watermark(const std::wstring &dir, unsigned long long &journal_id,
                               unsigned long long &next_usn) {
    journal_id = 0;
    next_usn = 0;
    std::wstring marker;
    if (!read_small_text_file(index_complete_file(dir), marker)) return false;
    std::wstring valid, jid, next;
    if (!marker_value(marker, L"usn_valid", valid) || valid != L"1") return false;
    if (!marker_value(marker, L"usn_journal", jid)) return false;
    if (!marker_value(marker, L"usn_next", next)) return false;
    journal_id = wcstoull(jid.c_str(), nullptr, 10);
    next_usn = wcstoull(next.c_str(), nullptr, 10);
    return journal_id != 0;
}

static bool replace_marker_value(std::wstring &marker, const wchar_t *name,
                                 const std::wstring &value) {
    std::wstring prefix = std::wstring(name) + L"=";
    size_t start = marker.find(prefix);
    if (start == std::wstring::npos || (start != 0 && marker[start - 1] != L'\n')) return false;
    start += prefix.size();
    size_t end = marker.find(L'\n', start);
    marker.replace(start, end == std::wstring::npos ? marker.size() - start : end - start, value);
    return true;
}

static bool write_file_if_changed(const std::wstring &file, const void *data, size_t bytes) {
    HANDLE existing = CreateFileW(file.c_str(), GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (existing != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER size = {};
        bool same = GetFileSizeEx(existing, &size) &&
                    size.QuadPart == static_cast<LONGLONG>(bytes);
        const unsigned char *expected = static_cast<const unsigned char *>(data);
        std::vector<unsigned char> chunk(64 * 1024);
        size_t offset = 0;
        while (same && offset < bytes) {
            DWORD wanted = static_cast<DWORD>(std::min<size_t>(chunk.size(), bytes - offset));
            DWORD got = 0;
            if (!ReadFile(existing, chunk.data(), wanted, &got, nullptr) || got != wanted ||
                memcmp(chunk.data(), expected + offset, wanted) != 0) {
                same = false;
                break;
            }
            offset += got;
        }
        CloseHandle(existing);
        if (same) return true;
    }
    HANDLE output = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) return false;
    bool ok = bytes == 0 || write_all(output, data, static_cast<DWORD>(bytes));
    CloseHandle(output);
    return ok;
}

static bool refresh_file_timestamp(const std::wstring &file) {
    HANDLE handle = CreateFileW(file.c_str(), FILE_WRITE_ATTRIBUTES,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    const bool ok = SetFileTime(handle, nullptr, &now, &now) != 0;
    CloseHandle(handle);
    return ok;
}

static bool advance_usn_watermark(const std::wstring &dir, unsigned long long journal_id,
                                  unsigned long long next_usn) {
    std::wstring marker;
    std::wstring final_file = index_complete_file(dir);
    if (!read_small_text_file(final_file, marker)) return false;
    if (!replace_marker_value(marker, L"usn_journal", std::to_wstring(journal_id)) ||
        !replace_marker_value(marker, L"usn_next", std::to_wstring(next_usn))) return false;
    std::wstring temp_file = final_file + L".advance." + std::to_wstring(GetCurrentProcessId());
    HANDLE h = CreateFileW(temp_file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    bool ok = write_all(h, marker.data(), static_cast<DWORD>(marker.size() * sizeof(wchar_t)));
    if (ok) ok = FlushFileBuffers(h) != 0;
    CloseHandle(h);
    if (ok) {
        ok = MoveFileExW(temp_file.c_str(), final_file.c_str(),
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
    }
    if (!ok) DeleteFileW(temp_file.c_str());
    return ok;
}

static bool key_is_parent_or_same(const std::wstring &child_key, const std::wstring &parent_key) {
    if (parent_key.empty()) return true;
    if (child_key == parent_key) return true;
    if (child_key.size() < parent_key.size() + 1) return false;
    if (child_key.compare(0, parent_key.size(), parent_key) != 0) return false;
    return child_key[parent_key.size()] == L'\\';
}

enum class JournalScopeResult {
    Unchanged,
    Affected,
    Unknown
};

static bool usn_debug_enabled() {
    wchar_t value[2] = {};
    return GetEnvironmentVariableW(L"DUSH_DEBUG_USN", value, 2) > 0 && value[0] == L'1';
}

static bool path_from_file_id(HANDLE volume, unsigned long long file_id, std::wstring &path) {
    path.clear();
    FILE_ID_DESCRIPTOR descriptor = {};
    descriptor.dwSize = sizeof(descriptor);
    descriptor.Type = FileIdType;
    descriptor.FileId.QuadPart = static_cast<LONGLONG>(file_id);
    HANDLE file = OpenFileById(volume, &descriptor, FILE_READ_ATTRIBUTES,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               nullptr, FILE_FLAG_BACKUP_SEMANTICS);
    if (file == INVALID_HANDLE_VALUE) {
        if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG open-id=%llu error=%lu\n", file_id, GetLastError());
        return false;
    }
    std::vector<wchar_t> buffer(32768);
    DWORD count = GetFinalPathNameByHandleW(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                                            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    if (!count || count >= buffer.size()) {
        if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG final-path id=%llu error=%lu\n", file_id, GetLastError());
        return false;
    }
    path.assign(buffer.data(), count);
    return true;
}

static bool paths_overlap(const std::wstring &a, const std::wstring &b) {
    return key_is_parent_or_same(a, b) || key_is_parent_or_same(b, a);
}

// Inspect only journal records created in [start_usn, end_usn). This avoids
// invalidating a folder snapshot when unrelated paths on the same busy volume
// change. Any record that cannot be resolved fails closed as Unknown.
static JournalScopeResult journal_changes_for_root(const std::wstring &root,
                                                   unsigned long long journal_id,
                                                   unsigned long long start_usn,
                                                   unsigned long long end_usn) {
    if (end_usn <= start_usn) return JournalScopeResult::Unchanged;
    if (root.size() < 2 || root[1] != L':') return JournalScopeResult::Unknown;
    std::wstring volume_path = L"\\\\.\\" + root.substr(0, 2);
    HANDLE volume = CreateFileW(volume_path.c_str(), GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (volume == INVALID_HANDLE_VALUE) {
        if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG open-volume error=%lu\n", GetLastError());
        return JournalScopeResult::Unknown;
    }

    const std::wstring root_key = normalized_key(root);
    READ_USN_JOURNAL_DATA request = {};
    request.StartUsn = static_cast<USN>(start_usn);
    request.ReasonMask = 0xffffffffu;
    request.ReturnOnlyOnClose = FALSE;
    request.Timeout = 0;
    request.BytesToWaitFor = 0;
    request.UsnJournalID = journal_id;
    std::vector<unsigned char> buffer(1024 * 1024);
    JournalScopeResult result = JournalScopeResult::Unchanged;

    while (static_cast<unsigned long long>(request.StartUsn) < end_usn) {
        DWORD bytes = 0;
        if (!DeviceIoControl(volume, FSCTL_READ_USN_JOURNAL,
                             &request, sizeof(request), buffer.data(),
                             static_cast<DWORD>(buffer.size()), &bytes, nullptr) ||
            bytes < sizeof(USN)) {
            if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG read-journal error=%lu bytes=%lu\n", GetLastError(), bytes);
            result = JournalScopeResult::Unknown;
            break;
        }
        USN next_usn = *reinterpret_cast<USN *>(buffer.data());
        if (next_usn <= request.StartUsn) {
            result = JournalScopeResult::Unknown;
            break;
        }
        DWORD offset = sizeof(USN);
        while (offset + sizeof(USN_RECORD) <= bytes) {
            USN_RECORD *record = reinterpret_cast<USN_RECORD *>(buffer.data() + offset);
            if (record->RecordLength < sizeof(USN_RECORD) || offset + record->RecordLength > bytes) {
                result = JournalScopeResult::Unknown;
                break;
            }
            unsigned long long record_usn = static_cast<unsigned long long>(record->Usn);
            if (record_usn >= end_usn) break;
            if (record_usn >= start_usn) {
                std::wstring candidate;
                std::wstring parent;
                if (path_from_file_id(volume, record->ParentFileReferenceNumber, parent)) {
                    const wchar_t *name = reinterpret_cast<const wchar_t *>(
                        reinterpret_cast<const unsigned char *>(record) + record->FileNameOffset);
                    candidate = join_path(display_path(parent),
                                          std::wstring(name, record->FileNameLength / sizeof(wchar_t)));
                } else if (!path_from_file_id(volume, record->FileReferenceNumber, candidate)) {
                    if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG unresolved-record frn=%llu parent=%llu name=%.*ls\n",
                        record->FileReferenceNumber, record->ParentFileReferenceNumber,
                        record->FileNameLength / static_cast<int>(sizeof(wchar_t)),
                        reinterpret_cast<const wchar_t *>(reinterpret_cast<const unsigned char *>(record) + record->FileNameOffset));
                    result = JournalScopeResult::Unknown;
                    break;
                }
                if (paths_overlap(normalized_key(candidate), root_key)) {
                    if (usn_debug_enabled()) fwprintf(stderr, L"USN_DEBUG affected candidate=%ls root=%ls\n", candidate.c_str(), root.c_str());
                    result = JournalScopeResult::Affected;
                    break;
                }
            }
            offset += record->RecordLength;
        }
        if (result != JournalScopeResult::Unchanged) break;
        request.StartUsn = next_usn;
    }
    CloseHandle(volume);
    return result;
}

static bool find_matching_index_dir(const std::wstring &parent, std::wstring &dir, bool &watched) {
    std::wstring parent_key = normalized_key(parent);
    std::wstring roots = index_roots_dir();
    std::wstring pattern = join_path(roots, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd,
                                FindExSearchNameMatch, nullptr, 0);
    if (h == INVALID_HANDLE_VALUE) return false;
    size_t best_len = 0;
    bool found = false;
    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
        std::wstring candidate = join_path(roots, fd.cFileName);
        bool candidate_watched = false;
        std::wstring candidate_root;
        unsigned long long candidate_built = 0;
        if (!read_complete_marker(candidate, candidate_watched, candidate_root, candidate_built)) continue;
        std::wstring key = normalized_key(candidate_root);
        if (key.size() <= best_len || !key_is_parent_or_same(parent_key, key)) continue;
        best_len = key.size();
        dir = candidate;
        watched = candidate_watched;
        found = true;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return found;
}

// True when the cached snapshot for `root` can no longer be trusted: either it
// has no USN watermark, the volume's journal cannot be read, or the journal has
// advanced past the watermark (i.e. the volume changed since the build).
static bool index_changed_since_build(const std::wstring &root) {
    std::wstring dir;
    bool watched = false;
    if (!find_matching_index_dir(root, dir, watched)) return true;
    unsigned long long stored_jid = 0, stored_next = 0;
    if (!read_usn_watermark(dir, stored_jid, stored_next)) return true;
    unsigned long long cur_jid = 0, cur_next = 0;
    if (!query_volume_usn(root, cur_jid, cur_next)) return true;
    return cur_jid != stored_jid || cur_next > stored_next;
}

static std::wstring flags(DWORD attrs) {
    wchar_t s[5] = {L'-', L'-', L'-', L'-', 0};
    if (attrs & FILE_ATTRIBUTE_HIDDEN) s[0] = L'H';
    if (attrs & FILE_ATTRIBUTE_SYSTEM) s[1] = L'S';
    if (attrs & FILE_ATTRIBUTE_READONLY) s[2] = L'R';
    if (attrs & FILE_ATTRIBUTE_ARCHIVE) s[3] = L'A';
    return std::wstring(s);
}

static std::wstring gib(unsigned long long bytes) {
    wchar_t buf[64];
    swprintf(buf, 64, L"%.3f GB", static_cast<double>(bytes) / (1024.0 * 1024.0 * 1024.0));
    return std::wstring(buf);
}

static std::wstring display_size(const Item &item, bool raw_bytes) {
    if (raw_bytes) {
        wchar_t buf[32];
        swprintf(buf, 32, L"%llu", item.bytes);
        return std::wstring(buf);
    }
    return gib(item.bytes);
}

static std::wstring display_size_gb(const Item &item, bool always_gb) {
    (void)always_gb;
    return gib(item.bytes);
}

static size_t table_name_width(const std::vector<Item> &items) {
    size_t width = 46;
    for (const auto &item : items) {
        size_t n = leaf_name(item.path).size() + (item.is_dir ? 1u : 0u);
        if (n > width) width = n;
    }
    return width;
}

// UTF-8 encode a wide string (for text files shared with other tools).
static std::vector<unsigned char> utf8_encode(const std::wstring &s) {
    std::vector<unsigned char> out;
    if (s.empty()) return out;
    int needed = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                                     nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return out;
    out.resize(static_cast<size_t>(needed));
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                        reinterpret_cast<char *>(out.data()), needed, nullptr, nullptr);
    return out;
}

// Shared cache consumed by rrm (ForceDeleteAnything.exe): the listing root plus
// the full absolute path of every numbered row, in the exact TSV format the delete
// tool reads from %ProgramData%\ForceDeleteAnything\last-numbered-items.tsv.
// Written on every table print so `rrm <number>` always matches the numbers shown
// here, in this exact sort order (dirs first, then size desc, then name).
static void write_rrm_shared_cache(const std::wstring &root, const std::vector<Item> &items) {
    wchar_t program_data[32768];
    if (SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, program_data) != S_OK) return;
    std::wstring dir = join_path(program_data, L"ForceDeleteAnything");
    if (!ensure_dir(dir)) return;
    std::wstring file = join_path(dir, L"last-numbered-items.tsv");
    std::vector<unsigned char> buf;
    std::wstring header = L"# ForceDeleteAnything numbered item cache v2\nroot=" +
                          display_path(root) + L"\n";
    std::vector<unsigned char> hb = utf8_encode(header);
    buf.insert(buf.end(), hb.begin(), hb.end());
    for (size_t i = 0; i < items.size(); ++i) {
        std::wstring line = std::to_wstring(i + 1) + L"\t" + display_path(items[i].path) + L"\n";
        std::vector<unsigned char> lb = utf8_encode(line);
        buf.insert(buf.end(), lb.begin(), lb.end());
    }
    // The cache is a proof of the most recent dush table, not merely a content
    // snapshot.  Refresh its timestamp even when USN verification produced the
    // same rows, otherwise rrm rejects a valid unchanged list after 30 minutes.
    if (write_file_if_changed(file, buf.data(), buf.size())) {
        refresh_file_timestamp(file);
    }
}

// Sidecar "row-number" cache: maps table row numbers to entry names so terminal
// integrations can jump to a row. Written right before the table is printed.
static bool write_rrm_number_cache(const std::wstring &root, const std::vector<Item> &items) {
    (void)root;
    // Kept next to the exe (not in the relocated index cache) so terminal
    // integrations that read this sidecar keep finding it at the same path.
    std::wstring file = join_path(join_path(exe_dir(), L"cache"), L"rrm-numbers.txt");
    if (!ensure_dir(join_path(exe_dir(), L"cache"))) return false;
    std::wstring text;
    for (size_t i = 0; i < items.size(); ++i) {
        text += std::to_wstring(i + 1);
        text += L"\t";
        text += leaf_name(items[i].path);
        text += L"\n";
    }
    bool ok = write_file_if_changed(file, text.data(), text.size() * sizeof(wchar_t));

    write_rrm_shared_cache(root, items);
    return ok;
}

static void append_u8(std::vector<unsigned char> &buf, unsigned char v) {
    buf.push_back(v);
}

static void append_u32(std::vector<unsigned char> &buf, unsigned int v) {
    const unsigned char *p = reinterpret_cast<const unsigned char *>(&v);
    buf.insert(buf.end(), p, p + sizeof(v));
}

static void append_u64(std::vector<unsigned char> &buf, unsigned long long v) {
    const unsigned char *p = reinterpret_cast<const unsigned char *>(&v);
    buf.insert(buf.end(), p, p + sizeof(v));
}

static void append_wstr(std::vector<unsigned char> &buf, const std::wstring &s) {
    unsigned int n = static_cast<unsigned int>(s.size());
    append_u32(buf, n);
    if (n) {
        const unsigned char *p = reinterpret_cast<const unsigned char *>(s.data());
        buf.insert(buf.end(), p, p + n * sizeof(wchar_t));
    }
}

// Serializes one directory's snapshot into the packed index format: the parent's
// normalized key, then its direct children with their recursive statistics.
static std::vector<unsigned char> serialize_parent(const std::wstring &parent_display,
                                                   const std::vector<Item> &items) {
    std::vector<unsigned char> buf;
    buf.reserve(items.size() * 96 + 128);
    append_wstr(buf, normalized_key(parent_display));
    append_u32(buf, static_cast<unsigned int>(items.size()));
    for (const auto &item : items) {
        append_wstr(buf, leaf_name(item.path));
        append_u8(buf, item.is_dir ? 1 : 0);
        append_u32(buf, item.attrs);
        append_u64(buf, item.bytes);
        append_u64(buf, item.files);
        append_u64(buf, item.dirs);
        append_u64(buf, item.inaccessible);
        append_u64(buf, item.reparse_dirs);
    }
    return buf;
}

// Parallel index builder: phase 1 scans every directory concurrently with the same
// worker pattern as the exact scanner; phase 2 does a single-threaded bottom-up pass
// to compute recursive totals and serialize each directory's snapshot. Results are
// packed into one index.bin file, so even a multi-million-entry tree indexes in
// roughly the time of one parallel scan.
class ParallelIndexBuilder {
    struct DirData {
        std::wstring dir;             // long-path form used for enumeration
        std::wstring key;             // normalized display key
        std::vector<Item> items;      // direct children (long-path form)
        bool enumerable = true;
        IndexBuildResult result;
    };

public:
    IndexBuildResult build(const std::wstring &root) {
        root_ = new DirData;
        root_->dir = root;
        root_->key = normalized_key(display_path(root));
        {
            std::lock_guard<std::mutex> lock(mu_);
            dirs_[root_->key] = root_;
            queue_.push_back(root_);
        }
        cv_.notify_all();
        run_scan();

        // Phase 2: single-threaded post-order accumulation + serialization.
        serialize(root_);
        write_index_file();

        IndexBuildResult result = root_->result;
        delete root_;
        root_ = nullptr;
        return result;
    }

private:
    void run_scan() {
        unsigned int threads = std::thread::hardware_concurrency();
        if (threads < 4) threads = 4;
        if (threads > 32) threads = 32;
        std::vector<std::thread> workers;
        workers.reserve(threads);
        for (unsigned int i = 0; i < threads; ++i) workers.emplace_back([this] { worker(); });
        {
            std::unique_lock<std::mutex> lock(mu_);
            cv_.wait(lock, [this] { return done_ || (queue_.empty() && active_ == 0); });
            done_ = true;
        }
        cv_.notify_all();
        for (auto &t : workers) t.join();
    }

    void worker() {
        for (;;) {
            DirData *d;
            {
                std::unique_lock<std::mutex> lock(mu_);
                cv_.wait(lock, [this] { return done_ || !queue_.empty(); });
                if (done_ || queue_.empty()) return;
                d = queue_.front();
                queue_.pop_front();
                ++active_;
            }
            scan(d);
            {
                std::lock_guard<std::mutex> lock(mu_);
                --active_;
                if (queue_.empty() && active_ == 0) {
                    done_ = true;
                    cv_.notify_all();
                }
            }
        }
    }

    void scan(DirData *d) {
        std::wstring pattern = join_path(d->dir, L"*");
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd,
                                    FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
        if (h == INVALID_HANDLE_VALUE) {
            d->enumerable = false;
            d->result.inaccessible = 1;
            return;
        }

        d->items.reserve(32);
        do {
            if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
            Item item;
            item.path = join_path(d->dir, fd.cFileName);
            item.attrs = fd.dwFileAttributes;
            item.is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            item.is_reparse = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            item.bytes = file_size(fd);
            if (item.is_dir) {
                item.dirs = 1;
                if (item.is_reparse) item.reparse_dirs = 1;
            } else {
                item.files = 1;
            }
            d->items.push_back(std::move(item));
        } while (FindNextFileW(h, &fd));
        FindClose(h);

        std::vector<DirData *> children;
        children.reserve(16);
        for (size_t i = 0; i < d->items.size(); ++i) {
            Item &item = d->items[i];
            if (!item.is_dir || item.is_reparse) continue;
            DirData *child = new DirData;
            child->dir = item.path;
            child->key = normalized_key(display_path(item.path));
            children.push_back(child);
        }
        if (!children.empty()) {
            std::lock_guard<std::mutex> lock(mu_);
            for (DirData *child : children) {
                dirs_[child->key] = child;
                if (!done_) queue_.push_back(child);
            }
            cv_.notify_all();
        }
    }

    // Post-order: children are accumulated and serialized before the parent, so every
    // Item's recursive totals are complete when its directory's record is written.
    IndexBuildResult serialize(DirData *d) {
        IndexBuildResult r = d->result;
        for (Item &item : d->items) {
            if (item.is_dir && !item.is_reparse) {
                auto it = dirs_.find(normalized_key(display_path(item.path)));
                if (it != dirs_.end()) {
                    IndexBuildResult child = serialize(it->second);
                    item.bytes += child.bytes;
                    item.files += child.files;
                    item.dirs += child.dirs;
                    item.inaccessible += child.inaccessible;
                    item.reparse_dirs += child.reparse_dirs;
                    delete it->second;
                    dirs_.erase(it);
                }
            }
            r.bytes += item.bytes;
            r.files += item.files;
            r.dirs += item.dirs;
            r.inaccessible += item.inaccessible;
            r.reparse_dirs += item.reparse_dirs;
        }
        d->result = r;
        if (d->enumerable) {
            Record rec;
            rec.hash = fnv1a64(d->key);
            rec.data = serialize_parent(display_path(d->dir), d->items);
            records_.push_back(std::move(rec));
        }
        return r;
    }

    void write_index_file() {
        unsigned int count = static_cast<unsigned int>(records_.size());
        unsigned long long table_offset = 8 + 8 + 4;
        for (const auto &r : records_) table_offset += r.data.size();

        std::wstring file = index_pack_file(index_dir());
        HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) return;
        const char magic[8] = {'D', 'U', 'S', 'H', 'I', 'D', 'X', '3'};
        bool ok = write_all(h, magic, 8) &&
                  write_all(h, &table_offset, sizeof(table_offset)) &&
                  write_all(h, &count, sizeof(count));
        for (const auto &r : records_) {
            if (!ok) break;
            ok = write_all(h, r.data.data(), static_cast<DWORD>(r.data.size()));
        }
        std::vector<std::pair<unsigned long long, unsigned long long>> table;
        table.reserve(records_.size());
        unsigned long long off = 8 + 8 + 4;
        for (const auto &r : records_) {
            table.emplace_back(r.hash, off);
            off += r.data.size();
        }
        std::sort(table.begin(), table.end());
        for (const auto &p : table) {
            if (!ok) break;
            ok = write_all(h, &p.first, sizeof(p.first)) &&
                 write_all(h, &p.second, sizeof(p.second));
        }
        CloseHandle(h);
    }

    struct Record {
        unsigned long long hash = 0;
        std::vector<unsigned char> data;
    };

    std::deque<DirData *> queue_;
    std::mutex mu_;
    std::condition_variable cv_;
    size_t active_ = 0;
    bool done_ = false;
    DirData *root_ = nullptr;
    std::unordered_map<std::wstring, DirData *> dirs_;
    std::vector<Record> records_;
};

static bool publish_index_for_root(const std::wstring &root, bool watched, IndexBuildResult &result, DWORD &err) {
    std::wstring final_cache = index_dir_for_root(display_path(root));
    std::wstring temp_cache = final_cache + L".build." + hex64(GetCurrentProcessId()) + L"." + hex64(GetTickCount64());
    remove_tree(temp_cache);
    g_index_output_dir = temp_cache;
    ensure_dir(temp_cache);

    ParallelIndexBuilder builder;
    result = builder.build(root);
    bool published = write_complete_marker(display_path(root), result, watched);
    if (published) {
        if (!watched) {
            // Only defer to a live watcher-owned cache; snapshot caches (including
            // older-format ones) are always replaced by this build.
            bool existing_watched = false;
            std::wstring existing_root;
            unsigned long long existing_built = 0;
            if (read_complete_marker(final_cache, existing_watched, existing_root, existing_built) &&
                existing_watched) {
                remove_tree(temp_cache);
                g_index_output_dir.clear();
                return true;
            }
        }
        published = false;
        for (int attempt = 0; attempt < 30; ++attempt) {
            bool removed = remove_tree(final_cache);
            if (MoveFileExW(temp_cache.c_str(), final_cache.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                published = true;
                break;
            }
            Sleep(100);
            if (!removed) break;
        }
        if (!published) remove_tree(temp_cache);
    } else {
        remove_tree(temp_cache);
    }
    g_index_output_dir.clear();
    if (!published) err = GetLastError();
    return published;
}

// Publish a packed index for `root` from an already-completed live scan (the
// root's direct children with recursive totals). One scan + one tiny write: the
// next query in this folder is served from the index INSTANTLY, but only when
// the volume USN journal proves nothing changed since this snapshot - so the
// cached numbers are exact by proof, never stale. Any doubt falls through to a
// fresh live scan.
static bool publish_index_from_memory(const std::wstring &root, const std::vector<Item> &items,
                                      IndexBuildResult &result) {
    std::wstring final_cache = index_dir_for_root(display_path(root));
    std::wstring temp_cache = final_cache + L".build." + hex64(GetCurrentProcessId()) + L"." + hex64(GetTickCount64());
    remove_tree(temp_cache);
    g_index_output_dir = temp_cache;
    ensure_dir(temp_cache);

    result = IndexBuildResult();
    for (const auto &it : items) {
        result.bytes += it.bytes;
        result.files += it.files;
        result.dirs += it.dirs;
        result.inaccessible += it.inaccessible;
        result.reparse_dirs += it.reparse_dirs;
    }

    // Single-record DUSHIDX3 index: the root's own parent record.
    std::wstring file = index_pack_file(index_dir());
    HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        remove_tree(temp_cache);
        g_index_output_dir.clear();
        return false;
    }
    std::vector<unsigned char> rec = serialize_parent(display_path(root), items);
    unsigned long long table_offset = 8 + 8 + 4 + rec.size();
    const char magic[8] = {'D', 'U', 'S', 'H', 'I', 'D', 'X', '3'};
    unsigned int one = 1;
    bool ok = write_all(h, magic, 8) &&
              write_all(h, &table_offset, sizeof(table_offset)) &&
              write_all(h, &one, sizeof(one)) &&
              write_all(h, rec.data(), static_cast<DWORD>(rec.size()));
    unsigned long long hash = fnv1a64(normalized_key(display_path(root)));
    unsigned long long off = 8 + 8 + 4;
    if (ok) ok = write_all(h, &hash, sizeof(hash)) && write_all(h, &off, sizeof(off));
    CloseHandle(h);
    if (!ok) {
        remove_tree(temp_cache);
        g_index_output_dir.clear();
        return false;
    }

    bool published = write_complete_marker(display_path(root), result, false);
    if (published) {
        for (int attempt = 0; attempt < 30; ++attempt) {
            bool removed = remove_tree(final_cache);
            if (MoveFileExW(temp_cache.c_str(), final_cache.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                published = true;
                break;
            }
            Sleep(100);
            if (!removed) break;
        }
        if (!published) remove_tree(temp_cache);
    } else {
        remove_tree(temp_cache);
    }
    g_index_output_dir.clear();
    return published;
}

// --watch-index: publish a watcher-backed cache, then poll the root's direct
// entries and republish whenever anything changes.
static int watch_index_loop(const std::wstring &root) {
    for (;;) {
        IndexBuildResult result;
        DWORD err = ERROR_SUCCESS;
        if (!publish_index_for_root(root, true, result, err)) {
            fwprintf(stderr, L"index publish failed: %lu\n", err);
            return 1;
        }
        wprintf(L"Watch indexed: %llu files, %llu folders, %.3f GB\n", result.files, result.dirs,
                static_cast<double>(result.bytes) / (1024.0 * 1024.0 * 1024.0));
        // Cheap fingerprint of the root's direct entries: (name, size, mtime, attrs).
        auto fingerprint = [&]() -> unsigned long long {
            std::wstring pattern = join_path(root, L"*");
            WIN32_FIND_DATAW fd;
            HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd,
                                        FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
            if (h == INVALID_HANDLE_VALUE) return 0;
            unsigned long long acc = 14695981039346656037ull;
            do {
                if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
                std::wstring s = fd.cFileName;
                for (wchar_t c : s) {
                    acc ^= static_cast<unsigned char>(c);
                    acc *= 1099511628211ull;
                }
                acc ^= file_size(fd);
                acc *= 1099511628211ull;
                acc ^= fd.ftLastWriteTime.dwLowDateTime;
                acc *= 1099511628211ull;
                acc ^= fd.ftLastWriteTime.dwHighDateTime;
                acc *= 1099511628211ull;
                acc ^= fd.dwFileAttributes;
                acc *= 1099511628211ull;
            } while (FindNextFileW(h, &fd));
            FindClose(h);
            return acc;
        };
        unsigned long long fp = fingerprint();
        for (;;) {
            Sleep(5000);
            if (fingerprint() != fp) break;
        }
    }
}

static bool load_parent_index_from_dir(const std::wstring &dir, const std::wstring &parent,
                                       std::vector<Item> &items) {
    std::wstring file = index_pack_file(dir);
    HANDLE h = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    char magic[8] = {};
    unsigned long long table_offset = 0;
    unsigned int count = 0;
    bool ok = read_exact(h, magic, 8) && std::memcmp(magic, "DUSHIDX3", 8) == 0 &&
              read_u64(h, table_offset) && read_u32(h, count);
    if (ok && count > 5000000u) ok = false;

    unsigned long long offset = 0;
    bool found = false;
    if (ok && count) {
        LARGE_INTEGER pos;
        pos.QuadPart = static_cast<LONGLONG>(table_offset);
        if (!SetFilePointerEx(h, pos, nullptr, FILE_BEGIN)) ok = false;
        std::vector<unsigned char> tbuf(static_cast<size_t>(count) * 16);
        if (ok) ok = read_exact(h, tbuf.data(), static_cast<DWORD>(tbuf.size()));
        unsigned long long target = fnv1a64(normalized_key(parent));
        long long lo = 0, hi = static_cast<long long>(count);
        while (ok && lo < hi) {
            long long mid = (lo + hi) / 2;
            unsigned long long mhash = 0;
            std::memcpy(&mhash, tbuf.data() + mid * 16, 8);
            if (mhash < target) {
                lo = mid + 1;
            } else if (mhash > target) {
                hi = mid;
            } else {
                std::memcpy(&offset, tbuf.data() + mid * 16 + 8, 8);
                found = true;
                break;
            }
        }
    }

    if (ok && found) {
        LARGE_INTEGER pos;
        pos.QuadPart = static_cast<LONGLONG>(offset);
        if (!SetFilePointerEx(h, pos, nullptr, FILE_BEGIN)) ok = false;
        std::wstring stored_parent;
        unsigned int n = 0;
        if (ok) ok = read_wstr(h, stored_parent) && stored_parent == normalized_key(parent) && read_u32(h, n);
        if (ok && n > 1000000u) ok = false;
        items.clear();
        if (ok) items.reserve(n);
        for (unsigned int i = 0; ok && i < n; ++i) {
            Item item;
            std::wstring name;
            unsigned char is_dir = 0;
            unsigned int attrs = 0;
            ok = read_wstr(h, name) && read_u8(h, is_dir) && read_u32(h, attrs) &&
                 read_u64(h, item.bytes) && read_u64(h, item.files) && read_u64(h, item.dirs) &&
                 read_u64(h, item.inaccessible) && read_u64(h, item.reparse_dirs);
            if (!ok) break;
            item.path = join_path(display_path(parent), name.c_str());
            item.is_dir = is_dir != 0;
            item.is_reparse = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            item.attrs = attrs;
            items.push_back(std::move(item));
        }
    }
    CloseHandle(h);
    return ok && found;
}

static bool load_parent_index(const std::wstring &parent, std::vector<Item> &items, bool &watched,
                              bool &stale) {
    stale = false;
    std::wstring dir;
    if (find_matching_index_dir(parent, dir, watched)) {
        return load_parent_index_from_dir(dir, parent, items);
    }
    std::wstring own_dir = index_dir_for_root(parent);
    if (load_parent_index_from_dir(own_dir, parent, items)) {
        watched = false;
        stale = true;
        return true;
    }
    return false;
}

static const unsigned long long SNAPSHOT_MAX_AGE_SECONDS = 24ull * 3600;

static std::wstring exe_path() {
    std::vector<wchar_t> buf(32768);
    DWORD got = GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
    if (!got) return L"";
    return std::wstring(buf.data(), got);
}

static std::wstring building_marker_file(const std::wstring &root) {
    return join_path(index_dir_for_root(root), L"building.txt");
}

static bool write_building_marker_for_pid(const std::wstring &root, DWORD pid) {
    if (pid == 0) return false;
    std::wstring file = building_marker_file(root);
    HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    unsigned long long start = static_cast<unsigned long long>(time(nullptr));
    wchar_t text[128];
    int n = swprintf(text, 128, L"pid=%lu\nstart=%llu\n", pid, start);
    bool ok = n > 0 && write_all(h, text, static_cast<DWORD>(n * sizeof(wchar_t)));
    CloseHandle(h);
    return ok;
}

static bool write_building_marker(const std::wstring &root) {
    return write_building_marker_for_pid(root, GetCurrentProcessId());
}

static bool read_building_marker(const std::wstring &root, DWORD &pid, unsigned long long &start) {
    pid = 0;
    start = 0;
    std::wstring text;
    if (!read_small_text_file(building_marker_file(root), text)) return false;
    std::wstring v;
    if (marker_value(text, L"pid", v)) pid = static_cast<DWORD>(wcstoul(v.c_str(), nullptr, 10));
    if (marker_value(text, L"start", v)) start = wcstoull(v.c_str(), nullptr, 10);
    return pid != 0;
}

static bool process_alive(DWORD pid) {
    if (pid == 0) return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return false;
    DWORD exit_code = 0;
    bool alive = GetExitCodeProcess(h, &exit_code) && exit_code == STILL_ACTIVE;
    CloseHandle(h);
    return alive;
}

static bool background_build_running(const std::wstring &root) {
    DWORD pid = 0;
    unsigned long long start = 0;
    if (!read_building_marker(root, pid, start)) return false;
    return process_alive(pid);
}

static bool spawn_background_index(const std::wstring &root) {
    std::wstring exe = exe_path();
    if (exe.empty()) return false;
    std::wstring cmd = L"\"" + exe + L"\" --build-index \"" + display_path(root) + L"\"";
    std::vector<wchar_t> cmdline(cmd.begin(), cmd.end());
    cmdline.push_back(L'\0');
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessW(exe.c_str(), cmdline.data(), nullptr, nullptr, FALSE,
                             CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                             nullptr, nullptr, &si, &pi);
    if (ok) {
        // Publish the child PID before returning so a second foreground query
        // cannot launch a duplicate index build during the startup race.
        (void)write_building_marker_for_pid(root, pi.dwProcessId);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    return ok != 0;
}

static unsigned long long unix_now() {
    return static_cast<unsigned long long>(time(nullptr));
}

static bool maybe_start_background_index(const std::wstring &root) {
    if (background_build_running(root)) return false;
    DeleteFileW(building_marker_file(root).c_str());
    return spawn_background_index(root);
}

static void print_index_table(const std::wstring &root_display, std::vector<Item> &items, bool watched,
                              bool stale, bool refreshing, int limit,
                              std::chrono::steady_clock::time_point started) {
    unsigned long long total = 0, files = 0, dirs = 0;
    unsigned long long inaccessible = 0, reparse_dirs = 0;
    for (const auto &item : items) {
        total += item.bytes;
        files += item.files;
        dirs += item.dirs;
        inaccessible += item.inaccessible;
        reparse_dirs += item.reparse_dirs;
    }
    std::sort(items.begin(), items.end(), item_display_less);
    const int name_width = static_cast<int>(table_name_width(items));
    const std::wstring name_rule(static_cast<size_t>(name_width), L'-');
    auto ended = std::chrono::steady_clock::now();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(ended - started).count();
    wprintf(L"\n");
    wprintf(L"Path    %ls\n", root_display.c_str());
    wprintf(L"Status  %ls", stale ? L"INDEXED STALE" : (watched ? L"INDEXED EXACT" : L"INDEXED SNAPSHOT"));
    if (refreshing) wprintf(L" - refreshing in background");
    if (reparse_dirs) wprintf(L"; %llu reparse folders skipped", reparse_dirs);
    if (inaccessible) wprintf(L"; %llu inaccessible folders", inaccessible);
    wprintf(L"\n");
    wprintf(L"Time    %.2f s\n", elapsed_ms / 1000.0);
    wprintf(L"Items   %llu files, %llu folders\n", files, dirs);
    wprintf(L"\n");
    write_rrm_number_cache(root_display, items);
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"No", name_width, L"Name", L"Type", L"Attr", L"Size");
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"-----", name_width, name_rule.c_str(), L"----", L"----", L"--------------");
    size_t shown = items.size();
    if (limit > 0 && static_cast<size_t>(limit) < shown) shown = static_cast<size_t>(limit);
    for (size_t i = 0; i < shown; ++i) {
        const wchar_t *kind = items[i].is_dir ? L"DIR" : L"FILE";
        std::wstring name = leaf_name(items[i].path);
        if (items[i].is_dir) name.append(L"\\");
        wprintf(L"%5llu  %-*ls  %-4ls  %-4ls  %14ls\n",
                static_cast<unsigned long long>(i + 1), name_width, name.c_str(), kind,
                flags(items[i].attrs).c_str(), display_size_gb(items[i], true).c_str());
    }
    if (limit > 0 && static_cast<size_t>(limit) < items.size()) {
        wprintf(L"... %llu more direct entries hidden by -n/--count\n",
                static_cast<unsigned long long>(items.size() - shown));
    }
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"-----", name_width, name_rule.c_str(), L"----", L"----", L"--------------");
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"", name_width, L"TOTAL", L"", L"", gib(total).c_str());
}

static void print_usage() {
    wprintf(L"dush C++ exact disk usage\n");
    wprintf(L"usage: dush [path] [--bytes] [--total-only] [-n count] [--threads count] [--max-seconds seconds] [--recursive-scan] [--no-auto-index]\n");
    wprintf(L"       dush --build-index [path]\n");
    wprintf(L"       dush --watch-index [path]\n");
    wprintf(L"default path is the current directory; hidden and system entries are included\n");
    wprintf(L"normal queries run a live all-core scan and verify with NTFS USN that the filesystem stayed stable\n");
    wprintf(L"after a live scan the result is cached with a USN-verified freshness proof: a repeat run that can be\n");
    wprintf(L"proven unchanged prints instantly (INDEXED FRESH); changes trigger a fresh scan and unstable scans are labeled INCOMPLETE\n");
    wprintf(L"use --no-auto-index to force a fresh live scan every run and skip cache read/write\n");
    wprintf(L"use --build-index to prebuild the packed index and --watch-index to keep it hot (explicit only)\n");
    wprintf(L"use --max-seconds only when you prefer a bounded best-effort PARTIAL scan\n");
    wprintf(L"one-shot indexed folders print INDEXED SNAPSHOT; watcher-backed folders print INDEXED EXACT\n");
}

// Shared table/total printer for both the live-scan path and the USN-verified
// instant-repeat path. Sorting, sidecar row caches and the TOTAL line are
// identical in both, so the two paths can never drift apart.
static void print_results(const std::wstring &root_display, std::vector<Item> &items,
                          bool total_only, bool bytes_only, int limit, const wchar_t *status,
                          bool deadline_hit, double max_seconds,
                          std::chrono::steady_clock::time_point started) {
    unsigned long long total = 0, files = 0, dirs = 0;
    unsigned long long inaccessible = 0, reparse_dirs = 0;
    for (const auto &item : items) {
        total += item.bytes;
        files += item.files;
        dirs += item.dirs;
        inaccessible += item.inaccessible;
        reparse_dirs += item.reparse_dirs;
    }

    if (total_only) {
        if (bytes_only) wprintf(L"%llu\n", total);
        else wprintf(L"%ls\n", gib(total).c_str());
        return;
    }

    std::sort(items.begin(), items.end(), item_display_less);
    const int name_width = static_cast<int>(table_name_width(items));
    const std::wstring name_rule(static_cast<size_t>(name_width), L'-');
    write_rrm_number_cache(root_display, items);
    auto ended = std::chrono::steady_clock::now();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(ended - started).count();
    wprintf(L"\n");
    wprintf(L"Path    %ls\n", root_display.c_str());
    wprintf(L"Status  %ls", status);
    if (reparse_dirs) wprintf(L"; %llu reparse folders skipped", reparse_dirs);
    if (inaccessible) wprintf(L"; %llu inaccessible folders", inaccessible);
    wprintf(L"\n");
    wprintf(L"Items   %llu files, %llu folders\n", files, dirs);
    wprintf(L"\n");
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"No", name_width, L"Name", L"Type", L"Attr", L"Size");
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"-----", name_width, name_rule.c_str(), L"----", L"----", L"--------------");
    size_t shown = items.size();
    if (limit > 0 && static_cast<size_t>(limit) < shown) shown = static_cast<size_t>(limit);
    for (size_t i = 0; i < shown; ++i) {
        const wchar_t *kind = items[i].is_dir ? L"DIR" : L"FILE";
        std::wstring name = leaf_name(items[i].path);
        if (items[i].is_dir) name.append(L"\\");
        wprintf(L"%5llu  %-*ls  %-4ls  %-4ls  %14ls\n",
                static_cast<unsigned long long>(i + 1), name_width, name.c_str(), kind,
                flags(items[i].attrs).c_str(), display_size(items[i], bytes_only).c_str());
    }
    if (limit > 0 && static_cast<size_t>(limit) < items.size()) {
        wprintf(L"... %llu more direct entries hidden by -n/--count\n",
                static_cast<unsigned long long>(items.size() - shown));
    }
    wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"-----", name_width, name_rule.c_str(), L"----", L"----", L"--------------");
    if (bytes_only) {
        wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14llu\n", L"", name_width, deadline_hit ? L"TOTAL SCANNED" : L"TOTAL", L"", L"", total);
    } else {
        wprintf(L"%5ls  %-*ls  %-4ls  %-4ls  %14ls\n", L"", name_width, deadline_hit ? L"TOTAL SCANNED" : L"TOTAL", L"", L"", gib(total).c_str());
    }
}

int wmain(int argc, wchar_t **argv) {
    bool bytes_only = false;
    bool total_only = false;
    bool build_index = false;
    bool watch_index = false;
    bool recursive_scan = true;
    bool no_auto_index = false;
    int limit = 0;
    unsigned int threads = 0;
    double max_seconds = 0.0;
    std::wstring target_arg;

    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--bytes") == 0) {
            bytes_only = true;
        } else if (wcscmp(argv[i], L"--total-only") == 0) {
            total_only = true;
        } else if (wcscmp(argv[i], L"--build-index") == 0) {
            build_index = true;
            if (i + 1 < argc && argv[i + 1][0] != L'-') target_arg = argv[++i];
        } else if (wcscmp(argv[i], L"--watch-index") == 0) {
            watch_index = true;
            if (i + 1 < argc && argv[i + 1][0] != L'-') target_arg = argv[++i];
        } else if (wcscmp(argv[i], L"--recursive-scan") == 0) {
            recursive_scan = true;
        } else if (wcscmp(argv[i], L"--no-auto-index") == 0) {
            no_auto_index = true;
        } else if ((wcscmp(argv[i], L"-n") == 0 || wcscmp(argv[i], L"--count") == 0) && i + 1 < argc) {
            limit = _wtoi(argv[++i]);
        } else if (wcscmp(argv[i], L"--threads") == 0 && i + 1 < argc) {
            threads = static_cast<unsigned int>(_wtoi(argv[++i]));
        } else if (wcscmp(argv[i], L"--max-seconds") == 0 && i + 1 < argc) {
            max_seconds = _wtof(argv[++i]);
        } else if (argv[i][0] != L'-') {
            target_arg = argv[i];
        } else {
            print_usage();
            return 2;
        }
    }

    std::wstring root;
    if (!target_arg.empty()) {
        wchar_t absbuf[32768];
        DWORD abslen = GetFullPathNameW(target_arg.c_str(), 32768, absbuf, nullptr);
        if (!abslen) {
            fwprintf(stderr, L"dush: bad path %ls\n", target_arg.c_str());
            return 1;
        }
        root.assign(absbuf, abslen);
    } else {
        wchar_t cwd[32768];
        DWORD got = GetCurrentDirectoryW(32768, cwd);
        if (!got) {
            fwprintf(stderr, L"dush: cannot get current directory\n");
            return 1;
        }
        root.assign(cwd, got);
    }
    while (root.size() > 1 && root.back() == L'\\') root.pop_back();
    root = long_path(root);
    auto started = std::chrono::steady_clock::now();

    if (watch_index) {
        ensure_dir(index_dir());
        return watch_index_loop(root);
    }

    if (build_index) {
        std::wstring build_display = display_path(root);
        ensure_dir(index_dir_for_root(build_display));
        write_building_marker(build_display);
        IndexBuildResult result;
        DWORD err = ERROR_SUCCESS;
        bool ok = publish_index_for_root(root, false, result, err);
        DeleteFileW(building_marker_file(build_display).c_str());
        if (!ok) {
            fwprintf(stderr, L"index publish failed: %lu\n", err);
            return 1;
        }
        wprintf(L"Indexed %ls: %llu files, %llu folders, %.3f GB\n",
                build_display.c_str(), result.files, result.dirs,
                static_cast<double>(result.bytes) / (1024.0 * 1024.0 * 1024.0));
        return 0;
    }

    std::wstring root_display = display_path(root);

    // Real-time by construction: a normal query is only ever served from the packed
    // index when the volume's USN journal PROVES nothing changed since that snapshot
    // was taken - the numbers are then exactly what a live scan would produce, but
    // returned instantly. Any doubt (no journal, journal reset, any change, unreadable)
    // falls through to the always-correct live scan below. Delete 20 GB and run dush
    // again and the difference shows immediately.
    std::vector<Item> items;
    if (!no_auto_index && recursive_scan && is_fast_index_drive_root(root_display)) {
        // Folder-size maintenance briefly marks the index unavailable while a
        // burst of USN changes is folded in. Retrying here avoids the old
        // multi-second full-scan spike after normal filesystem activity.
        const auto retry_until = started + std::chrono::milliseconds(1550);
        do {
            items.clear();
            if (query_fast_drive_index(root_display, items)) {
                // The package-local row sidecar lives on F: and can stall for
                // seconds when that removable volume is applying metadata
                // changes. Drive-root output updates the authoritative shared
                // rrm cache on C: only; ordinary folder scans retain both files.
                print_results(root_display, items, total_only, bytes_only, limit,
                              L"LIVE NTFS INDEX - complete monitored metadata", false,
                              max_seconds, started);
                return 0;
            }
            if (!FindWindowW(L"EVERYTHING_TASKBAR_NOTIFICATION_(DUSH)", nullptr)) break;
            Sleep(15);
        } while (std::chrono::steady_clock::now() < retry_until);
    }
    if (!no_auto_index && recursive_scan) {
        std::wstring idx_dir;
        bool idx_watched = false;
        if (find_matching_index_dir(root_display, idx_dir, idx_watched)) {
            unsigned long long stored_jid = 0, stored_next = 0;
            unsigned long long cur_jid = 0, cur_next = 0;
            if (read_usn_watermark(idx_dir, stored_jid, stored_next) &&
                query_volume_usn(root_display, cur_jid, cur_next) &&
                cur_jid == stored_jid && cur_next >= stored_next &&
                journal_changes_for_root(root_display, stored_jid, stored_next, cur_next) ==
                    JournalScopeResult::Unchanged) {
                if (load_parent_index_from_dir(idx_dir, root_display, items)) {
                    advance_usn_watermark(idx_dir, cur_jid, cur_next);
                    print_results(root_display, items, total_only, bytes_only, limit,
                                  L"INDEXED FRESH - USN-verified requested tree unchanged",
                                  false, max_seconds, started);
                    return 0;
                }
            }
        }
    }
    // Bracket the live enumeration with USN watermarks. A scan that overlaps a
    // filesystem mutation is useful, but cannot truthfully be called exact or be
    // cached as a coherent snapshot.
    unsigned long long scan_journal_id = 0, scan_start_usn = 0;
    const bool scan_has_start_usn = query_volume_usn(root_display, scan_journal_id, scan_start_usn);

    std::wstring pattern = join_path(root, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd,
                                FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (h == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"dush: cannot enumerate %ls\n", root_display.c_str());
        return 1;
    }
    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
        Item item;
        item.path = join_path(root, fd.cFileName);
        item.attrs = fd.dwFileAttributes;
        item.is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        item.is_reparse = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
        item.bytes = file_size(fd);
        if (item.is_dir) {
            item.dirs = 1;
            if (item.is_reparse) item.reparse_dirs = 1;
        } else {
            item.files = 1;
        }
        items.push_back(std::move(item));
    } while (FindNextFileW(h, &fd));
    FindClose(h);

    // Parallel recursive sizing with an optional deadline.
    struct ScanJob {
        Item *item;                // directory whose totals accumulate here
        ScanJob *parent;           // null for root-level dirs
        std::vector<Item> children;  // owns child entries (must outlive child jobs)
        std::atomic<size_t> pending{0};
        std::atomic<bool> scanned{false};
        std::atomic<bool> finished{false};
    };
    std::deque<ScanJob *> job_queue;
    std::mutex job_mu;
    std::condition_variable job_cv;
    size_t job_active = 0;
    bool job_done = false;
    bool deadline_hit = false;
    auto deadline = std::chrono::steady_clock::time_point::max();
    if (max_seconds > 0.0) {
        deadline = started + std::chrono::milliseconds(static_cast<long long>(max_seconds * 1000.0));
    }

    auto enqueue_job = [&](Item *item, ScanJob *parent) {
        ScanJob *job = new ScanJob;
        job->item = item;
        job->parent = parent;
        {
            std::lock_guard<std::mutex> lock(job_mu);
            job_queue.push_back(job);
        }
        job_cv.notify_one();
    };

    // Exactly one caller (the dir's own scan, or the last of its children) finishes a
    // job. When a directory finishes, its completed recursive totals are propagated into
    // the parent directory's item; when the parent's last child finishes, the parent is
    // finished (and propagated upward) in turn.
    std::function<void(ScanJob *)> maybe_finish;
    maybe_finish = [&](ScanJob *job) {
        bool expected = false;
        if (!job->finished.compare_exchange_strong(expected, true)) return;
        ScanJob *p = job->parent;
        if (p) {
            p->item->bytes += job->item->bytes;
            p->item->files += job->item->files;
            p->item->dirs += job->item->dirs;
            p->item->inaccessible += job->item->inaccessible;
            p->item->reparse_dirs += job->item->reparse_dirs;
            if (--p->pending == 0 && p->scanned.load()) maybe_finish(p);
        }
        delete job;
    };

    auto scan_one_dir = [&](ScanJob *job) {
        if (std::chrono::steady_clock::now() >= deadline) {
            deadline_hit = true;
            job->scanned.store(true);
            if (job->pending.load() == 0) maybe_finish(job);
            return;
        }
        std::wstring dpat = join_path(job->item->path, L"*");
        WIN32_FIND_DATAW sfd;
        HANDLE sh = FindFirstFileExW(dpat.c_str(), FindExInfoBasic, &sfd,
                                     FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
        if (sh == INVALID_HANDLE_VALUE) {
            job->item->inaccessible = 1;
            job->scanned.store(true);
            if (job->pending.load() == 0) maybe_finish(job);
            return;
        }
        job->children.reserve(32);
        do {
            if (wcscmp(sfd.cFileName, L".") == 0 || wcscmp(sfd.cFileName, L"..") == 0) continue;
            const bool is_dir = (sfd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            if (!is_dir) {
                job->item->bytes += file_size(sfd);
                job->item->files += 1;
                continue;
            }
            Item c;
            c.path = join_path(job->item->path, sfd.cFileName);
            c.attrs = sfd.dwFileAttributes;
            c.is_dir = true;
            c.is_reparse = (sfd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            c.bytes = file_size(sfd);
            c.dirs = 1;
            if (c.is_reparse) c.reparse_dirs = 1;
            job->children.push_back(std::move(c));
        } while (FindNextFileW(sh, &sfd));
        FindClose(sh);

        size_t subdirs = 0;
        for (const auto &c : job->children) {
            if (c.is_dir && !c.is_reparse && recursive_scan) ++subdirs;
        }
        job->pending.store(subdirs);
        for (auto &c : job->children) {
            if (c.is_dir && !c.is_reparse && recursive_scan) {
                enqueue_job(&c, job);
            }
        }
        // Direct files were accumulated during enumeration. Add reparse/non-recursive
        // dirs now; real subdirs get
        // a child job and propagate their completed totals via maybe_finish, so they
        // must NOT be added here (that would both undercount and double-count).
        for (const auto &c : job->children) {
            if (c.is_reparse || !recursive_scan) {
                job->item->bytes += c.bytes;
                job->item->dirs += c.dirs;
                job->item->inaccessible += c.inaccessible;
                job->item->reparse_dirs += c.reparse_dirs;
            }
        }
        job->scanned.store(true);
        if (job->pending.load() == 0) maybe_finish(job);
    };

    // Directory enumeration is storage-latency bound. A wider queue substantially
    // outperforms one worker per logical CPU on the current large F:/N: trees.
    const bool scanning_drive_root = root_display.size() == 2 && root_display[1] == L':';
    unsigned int worker_threads = threads > 0 ? threads :
        std::thread::hardware_concurrency() * (scanning_drive_root ? 16 : 12);
    if (worker_threads < 1) worker_threads = 1;
    if (worker_threads > 256) worker_threads = 256;
    std::vector<std::thread> workers;
    workers.reserve(worker_threads);
    for (unsigned int i = 0; i < worker_threads; ++i) {
        workers.emplace_back([&]() {
            for (;;) {
                ScanJob *job;
                {
                    std::unique_lock<std::mutex> lock(job_mu);
                    job_cv.wait(lock, [&] { return job_done || !job_queue.empty(); });
                    if (job_done && job_queue.empty()) return;
                    if (job_queue.empty()) continue;
                    job = job_queue.front();
                    job_queue.pop_front();
                    ++job_active;
                }
                scan_one_dir(job);
                {
                    std::lock_guard<std::mutex> lock(job_mu);
                    --job_active;
                    if (job_queue.empty() && job_active == 0) {
                        job_done = true;
                        job_cv.notify_all();
                    }
                }
            }
        });
    }
    {
        std::lock_guard<std::mutex> lock(job_mu);
        for (auto &it : items) {
            if (it.is_dir && !it.is_reparse) {
                ScanJob *job = new ScanJob;
                job->item = &it;
                job->parent = nullptr;
                job_queue.push_back(job);
            }
        }
        if (job_queue.empty()) {
            job_done = true;
        }
    }
    job_cv.notify_all();
    for (auto &t : workers) t.join();

    // Sort now. Sidecars are written only after the end watermark so this program's
    // own output bookkeeping cannot make a stable scan appear concurrent/unstable.
    std::sort(items.begin(), items.end(), [](const Item &a, const Item &b) {
        if (a.is_dir != b.is_dir) return a.is_dir > b.is_dir;
        if (a.bytes != b.bytes) return a.bytes > b.bytes;
        return _wcsicmp(a.path.c_str(), b.path.c_str()) < 0;
    });
    unsigned long long scan_end_journal_id = 0, scan_end_usn = 0;
    const bool scan_has_end_usn = query_volume_usn(root_display, scan_end_journal_id, scan_end_usn);
    const bool scan_stable = !scan_has_start_usn ||
        (scan_has_end_usn && scan_journal_id == scan_end_journal_id &&
         scan_end_usn >= scan_start_usn &&
         journal_changes_for_root(root_display, scan_journal_id, scan_start_usn, scan_end_usn) ==
             JournalScopeResult::Unchanged);
    unsigned long long inaccessible_total = 0;
    for (const auto &it : items) inaccessible_total += it.inaccessible;

    std::wstring status_label;
    if (deadline_hit) status_label = L"PARTIAL - time limit reached";
    else if (!scan_stable) status_label = L"INCOMPLETE - filesystem changed during scan; run again";
    else if (inaccessible_total) status_label = L"INCOMPLETE - one or more folders could not be read";
    else if (!scan_has_start_usn) status_label = L"EXACT ENUMERATION - concurrent-change proof unavailable";
    else status_label = L"EXACT - USN-verified stable during scan";

    // Do this before publishing the cache marker: when the sidecar lives on the
    // scanned volume, the marker must capture the USN generated by this write.
    if (!no_auto_index && !deadline_hit && scan_stable && inaccessible_total == 0) {
        // Publish the exact snapshot already held in memory first.  This is a
        // tiny single-record write, so a second dush invocation can use the
        // verified result immediately even while the complete recursive index
        // is being prepared by the detached worker below.
        IndexBuildResult snapshot;
        if (publish_index_from_memory(root, items, snapshot)) {
            status_label += L" (index snapshot saved)";
        }

        // The exact foreground scan is already complete.  Building the packed
        // recursive index can be much slower than producing this table, so do
        // it in a detached verified worker and never make the interactive dush
        // result wait for cache maintenance.
        if (maybe_start_background_index(root_display)) {
            status_label += L" (index refresh scheduled)";
        }
    }
    print_results(root_display, items, total_only, bytes_only, limit,
                  status_label.c_str(), deadline_hit, max_seconds, started);
    return 0;
}
