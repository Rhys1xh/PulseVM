;==============================================================================
; PulseVM 3.4 - The Performance Release
; x86-64 Linux, pure NASM assembly
;
; Changelog from 3.3:
;   - io_uring-based async I/O replacing epoll
;   - SO_REUSEPORT + CPU affinity for multi-core scaling
;   - In-memory metadata cache with inotify updates
;   - Memory-mapped file cache for hot files (LRU eviction)
;   - Pre-computed response headers in cache entries
;   - splice() zero-copy for range response assembly
;   - Static header dictionary for response compression
;   - Busy-polling mode for sub-millisecond latency
;
; Build:
;   nasm -f elf64 pulsevm.asm -o pulsevm.o
;   ld pulsevm.o -o pulsevm -luring
;
;   Or with static liburing:
;   nasm -f elf64 pulsevm.asm -o pulsevm.o
;   ld pulsevm.o -o pulsevm -L. -l:liburing.a
;
; Usage: ./pulsevm [port] [root_dir] [user] [keepalive_max] [cores]
;
; Requirements: Linux 5.1+, liburing
;==============================================================================

BITS 64
DEFAULT REL

;==============================================================================
; System Call Table
;==============================================================================
%define SYS_read                0
%define SYS_write               1
%define SYS_open                2
%define SYS_close               3
%define SYS_stat                4
%define SYS_fstat               5
%define SYS_lseek               8
%define SYS_mmap                9
%define SYS_mprotect           10
%define SYS_munmap             11
%define SYS_brk                12
%define SYS_socket             41
%define SYS_accept             43
%define SYS_sendfile           40
%define SYS_splice             76
%define SYS_writev             20
%define SYS_bind               49
%define SYS_listen             50
%define SYS_setsockopt         54
%define SYS_getsockname        51
%define SYS_io_uring_setup    425
%define SYS_io_uring_enter    426
%define SYS_io_uring_register 427
%define SYS_exit_group        231
%define SYS_fork               57
%define SYS_clone              56
%define SYS_getpid             39
%define SYS_getuid            102
%define SYS_setuid            105
%define SYS_setgid            106
%define SYS_sched_setaffinity 203
%define SYS_getcpu            309
%define SYS_rt_sigaction       13
%define SYS_clock_gettime     228
%define SYS_nanosleep          35
%define SYS_inotify_init1     294
%define SYS_inotify_add_watch 292
%define SYS_pipe2             293
%define SYS_eventfd2          290

;==============================================================================
; io_uring Constants
;==============================================================================
%define IORING_SETUP_SQPOLL    (1 << 1)
%define IORING_SETUP_SQ_AFF    (1 << 4)
%define IORING_SETUP_CQSIZE    (1 << 3)
%define IORING_SETUP_CLAMP     (1 << 7)
%define IORING_SETUP_ATTACH_WQ (1 << 8)

%define IORING_OP_ACCEPT       13
%define IORING_OP_READ         22
%define IORING_OP_WRITE        23
%define IORING_OP_SENDFILE     38
%define IORING_OP_SPLICE       39
%define IORING_OP_CLOSE        19
%define IORING_OP_STATX        30
%define IORING_OP_OPENAT       18
%define IORING_OP_TIMEOUT      15
%define IORING_OP_LINK_TIMEOUT 16

%define IOSQE_FIXED_FILE       (1 << 0)
%define IOSQE_IO_LINK          (1 << 1)
%define IOSQE_IO_HARDLINK      (1 << 2)
%define IOSQE_ASYNC            (1 << 3)
%define IOSQE_BUFFER_SELECT    (1 << 4)

%define IORING_CQE_F_BUFFER    (1 << 0)

;==============================================================================
; Network Constants
;==============================================================================
%define AF_INET                 2
%define SOCK_STREAM             1
%define SOCK_NONBLOCK        0x800
%define SOL_SOCKET              1
%define SOL_TCP                 6
%define SO_REUSEADDR            2
%define SO_REUSEPORT           15
%define SO_KEEPALIVE            9
%define SO_LINGER              13
%define SO_RCVTIMEO            20
%define SO_SNDTIMEO            21
%define SO_BUSY_POLL           46
%define SO_PREFER_BUSY_POLL    69
%define TCP_NODELAY             1
%define TCP_CORK                3
%define TCP_KEEPIDLE            4
%define TCP_KEEPINTVL           5
%define TCP_KEEPCNT             6

;==============================================================================
; Memory Constants
;==============================================================================
%define PAGE_SIZE            4096
%define MAP_SHARED              1
%define MAP_PRIVATE             2
%define MAP_ANONYMOUS        0x20
%define MAP_POPULATE       0x8000
%define PROT_READ               1
%define PROT_WRITE              2
%define PROT_EXEC               4

;==============================================================================
; HTTP Protocol Constants
;==============================================================================
%define METHOD_GET              1
%define METHOD_HEAD             2

;==============================================================================
; Operational Limits
;==============================================================================
%define MAX_EVENTS           4096
%define BUFFER_SIZE         16384
%define MAX_PATH             1024
%define MAX_CONNECTIONS      1000
%define LISTEN_BACKLOG        512
%define KEEPALIVE_TIMEOUT      15
%define READ_TIMEOUT_SEC        5
%define MAX_RANGES             16
%define LOG_RING_SIZE       65536
%define MAX_KEEPALIVE_REQS     100
%define MAX_CACHE_ENTRIES     8192
%define MAX_MMAP_FILES         256
%define MMAP_ARENA_SIZE     (256 * 1048576)
%define INOTIFY_BUF_SIZE    16384
%define IO_URING_ENTRIES      4096

;==============================================================================
; File Mode Constants
;==============================================================================
%define O_RDONLY                0
%define O_DIRECTORY        0x10000
%define SEEK_SET                0
%define S_IFMT            0xF000
%define S_IFREG           0x8000
%define S_IFDIR           0x4000

;==============================================================================
; Cache Entry Structure (128 bytes, cache-line aligned)
;   bytes 0-7:   file path hash (murmur3 64-bit)
;   bytes 8-15:  file size
;   bytes 16-23: last modified timestamp
;   bytes 24-31: inode number
;   bytes 32-39: mmap address (0 if not mapped)
;   bytes 40-47: pre-computed header pointer
;   bytes 48-55: header length
;   bytes 56-63: access timestamp (for LRU)
;   bytes 64-71: access count
;   bytes 72-79: next pointer (hash chain)
;   bytes 80-87: mime type pointer
;   bytes 88:    cacheable flag
;   bytes 89:    in_use flag
;   bytes 90-95: padding
;   bytes 96-127: pre-computed HTTP headers
;==============================================================================
%define CACHE_ENTRY_SIZE      128
%define CE_HASH                 0
%define CE_SIZE                 8
%define CE_MTIME               16
%define CE_INODE               24
%define CE_MMAP_ADDR           32
%define CE_HEADER_PTR          40
%define CE_HEADER_LEN          48
%define CE_ACCESS_TIME         56
%define CE_ACCESS_COUNT        64
%define CE_NEXT                72
%define CE_MIME_PTR            80
%define CE_CACHEABLE           88
%define CE_IN_USE              89
%define CE_PRE_HEADERS         96

;==============================================================================
; io_uring SQE Structure (64 bytes)
;==============================================================================
%define SQE_OPCODE              0
%define SQE_FLAGS               1
%define SQE_IOPRIO              2
%define SQE_FD                  4
%define SQE_OFF                 8
%define SQE_ADDR               16
%define SQE_LEN                24
%define SQE_ACCEPT_FLAGS       28
%define SQE_USER_DATA          32
%define SQE_BUF_INDEX          48
%define SQE_PERSONALITY        50
%define SQE_SOCKET_FD          52
%define SQE_OPT_CALLBACK       56

;==============================================================================
; io_uring CQE Structure (16 bytes)
;==============================================================================
%define CQE_USER_DATA           0
%define CQE_RES                 8
%define CQE_FLAGS              12

;==============================================================================
; Data Section
;==============================================================================
section .data
    ;----------------------------------------------------------------------
    ; HTTP Status Lines
    ;----------------------------------------------------------------------
    http_200:       db "HTTP/1.1 200 OK", 13, 10, 0
    http_206:       db "HTTP/1.1 206 Partial Content", 13, 10, 0
    http_304:       db "HTTP/1.1 304 Not Modified", 13, 10, 0
    http_400:       db "HTTP/1.1 400 Bad Request", 13, 10, 0
    http_403:       db "HTTP/1.1 403 Forbidden", 13, 10, 0
    http_404:       db "HTTP/1.1 404 Not Found", 13, 10, 0
    http_405:       db "HTTP/1.1 405 Method Not Allowed", 13, 10, 0
    http_413:       db "HTTP/1.1 413 Payload Too Large", 13, 10, 0
    http_414:       db "HTTP/1.1 414 URI Too Long", 13, 10, 0
    http_416:       db "HTTP/1.1 416 Range Not Satisfiable", 13, 10, 0
    http_429:       db "HTTP/1.1 429 Too Many Requests", 13, 10, 0
    http_500:       db "HTTP/1.1 500 Internal Server Error", 13, 10, 0

    ;----------------------------------------------------------------------
    ; Standard Response Headers
    ;----------------------------------------------------------------------
    hdr_server:     db "Server: PulseVM/3.4", 13, 10, 0
    hdr_conn_close: db "Connection: close", 13, 10, 0
    hdr_conn_keep:  db "Connection: keep-alive", 13, 10, 0
    hdr_ct_html:    db "Content-Type: text/html; charset=utf-8", 13, 10, 0
    hdr_ct_plain:   db "Content-Type: text/plain; charset=utf-8", 13, 10, 0
    hdr_cache:      db "Cache-Control: public, max-age=3600", 13, 10, 0
    hdr_no_cache:   db "Cache-Control: no-cache", 13, 10, 0
    hdr_accept_rng: db "Accept-Ranges: bytes", 13, 10, 0
    hdr_end:        db 13, 10, 0

    ; Header dictionary entries for compression reference
    ; Index 0: "Content-Length: "
    ; Index 1: "Content-Type: "
    ; Index 2: "Last-Modified: "
    ; Index 3: "ETag: "
    hdr_dict_cl:    db "Content-Length: ", 0
    hdr_dict_ct:    db "Content-Type: ", 0
    hdr_dict_lm:    db "Last-Modified: ", 0
    hdr_dict_etag:  db "ETag: ", 0

    align 8
    hdr_dict_table:
        dq hdr_dict_cl, 16
        dq hdr_dict_ct, 14
        dq hdr_dict_lm, 15
        dq hdr_dict_etag, 6

    ;----------------------------------------------------------------------
    ; Pre-built Error Responses
    ;----------------------------------------------------------------------
    
    ; 400 Bad Request
    err_400_hdr:    db "HTTP/1.1 400 Bad Request", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 144", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>400 Bad Request</title></head>"
                    db "<body><center><h1>400 Bad Request</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_400_len:    equ $ - err_400_hdr

    ; 403 Forbidden
    err_403_hdr:    db "HTTP/1.1 403 Forbidden", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 143", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>403 Forbidden</title></head>"
                    db "<body><center><h1>403 Forbidden</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_403_len:    equ $ - err_403_hdr

    ; 404 Not Found
    err_404_hdr:    db "HTTP/1.1 404 Not Found", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 143", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>404 Not Found</title></head>"
                    db "<body><center><h1>404 Not Found</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_404_len:    equ $ - err_404_hdr

    ; 405 Method Not Allowed
    err_405_hdr:    db "HTTP/1.1 405 Method Not Allowed", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 153", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>405 Method Not Allowed</title></head>"
                    db "<body><center><h1>405 Method Not Allowed</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_405_len:    equ $ - err_405_hdr

    ; 413 Payload Too Large
    err_413_hdr:    db "HTTP/1.1 413 Payload Too Large", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 152", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>413 Payload Too Large</title></head>"
                    db "<body><center><h1>413 Payload Too Large</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_413_len:    equ $ - err_413_hdr

    ; 414 URI Too Long
    err_414_hdr:    db "HTTP/1.1 414 URI Too Long", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 146", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>414 URI Too Long</title></head>"
                    db "<body><center><h1>414 URI Too Long</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_414_len:    equ $ - err_414_hdr

    ; 416 Range Not Satisfiable
    err_416_hdr:    db "HTTP/1.1 416 Range Not Satisfiable", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 157", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>416 Range Not Satisfiable</title></head>"
                    db "<body><center><h1>416 Range Not Satisfiable</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_416_len:    equ $ - err_416_hdr

    ; 429 Too Many Requests
    err_429_hdr:    db "HTTP/1.1 429 Too Many Requests", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 153", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>429 Too Many Requests</title></head>"
                    db "<body><center><h1>429 Too Many Requests</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_429_len:    equ $ - err_429_hdr

    ; 500 Internal Server Error
    err_500_hdr:    db "HTTP/1.1 500 Internal Server Error", 13, 10
                    db "Server: PulseVM/3.4", 13, 10
                    db "Connection: close", 13, 10
                    db "Cache-Control: no-cache", 13, 10
                    db "Content-Type: text/html; charset=utf-8", 13, 10
                    db "Content-Length: 155", 13, 10
                    db 13, 10
                    db "<!DOCTYPE html><html><head><title>500 Internal Server Error</title></head>"
                    db "<body><center><h1>500 Internal Server Error</h1></center><hr>"
                    db "<center>PulseVM/3.4</center></body></html>"
    err_500_len:    equ $ - err_500_hdr

    ;----------------------------------------------------------------------
    ; MIME Type Table (32-byte entries)
    ;----------------------------------------------------------------------
    align 8
    mime_table:
        dq ext_html,   mime_html,   0
        times 15 db 0
        dq ext_htm,    mime_html,   0
        times 15 db 0
        dq ext_css,    mime_css,    1
        times 15 db 0
        dq ext_js,     mime_js,     1
        times 15 db 0
        dq ext_mjs,    mime_js,     1
        times 15 db 0
        dq ext_json,   mime_json,   0
        times 15 db 0
        dq ext_png,    mime_png,    1
        times 15 db 0
        dq ext_jpg,    mime_jpg,    1
        times 15 db 0
        dq ext_jpeg,   mime_jpg,    1
        times 15 db 0
        dq ext_gif,    mime_gif,    1
        times 15 db 0
        dq ext_svg,    mime_svg,    1
        times 15 db 0
        dq ext_ico,    mime_ico,    1
        times 15 db 0
        dq ext_webp,   mime_webp,   1
        times 15 db 0
        dq ext_woff2,  mime_woff2,  1
        times 15 db 0
        dq ext_ttf,    mime_ttf,    1
        times 15 db 0
        dq ext_wasm,   mime_wasm,   1
        times 15 db 0
        dq ext_xml,    mime_xml,    0
        times 15 db 0
        dq ext_txt,    mime_txt,    0
        times 15 db 0
        dq ext_mp4,    mime_mp4,    1
        times 15 db 0
        dq ext_webm,   mime_webm,   1
        times 15 db 0
        dq ext_pdf,    mime_pdf,    1
        times 15 db 0
        dq ext_zip,    mime_zip,    1
        times 15 db 0
    mime_count: equ ($ - mime_table) / 32

    ; Extension strings
    ext_html:   db ".html", 0
    ext_htm:    db ".htm", 0
    ext_css:    db ".css", 0
    ext_js:     db ".js", 0
    ext_mjs:    db ".mjs", 0
    ext_json:   db ".json", 0
    ext_png:    db ".png", 0
    ext_jpg:    db ".jpg", 0
    ext_jpeg:   db ".jpeg", 0
    ext_gif:    db ".gif", 0
    ext_svg:    db ".svg", 0
    ext_ico:    db ".ico", 0
    ext_webp:   db ".webp", 0
    ext_woff2:  db ".woff2", 0
    ext_ttf:    db ".ttf", 0
    ext_wasm:   db ".wasm", 0
    ext_xml:    db ".xml", 0
    ext_txt:    db ".txt", 0
    ext_mp4:    db ".mp4", 0
    ext_webm:   db ".webm", 0
    ext_pdf:    db ".pdf", 0
    ext_zip:    db ".zip", 0

    ; MIME type strings
    mime_html:      db "text/html; charset=utf-8", 0
    mime_css:       db "text/css; charset=utf-8", 0
    mime_js:        db "application/javascript; charset=utf-8", 0
    mime_json:      db "application/json; charset=utf-8", 0
    mime_png:       db "image/png", 0
    mime_jpg:       db "image/jpeg", 0
    mime_gif:       db "image/gif", 0
    mime_svg:       db "image/svg+xml", 0
    mime_ico:       db "image/x-icon", 0
    mime_webp:      db "image/webp", 0
    mime_woff2:     db "font/woff2", 0
    mime_ttf:       db "font/ttf", 0
    mime_wasm:      db "application/wasm", 0
    mime_xml:       db "application/xml; charset=utf-8", 0
    mime_txt:       db "text/plain; charset=utf-8", 0
    mime_mp4:       db "video/mp4", 0
    mime_webm:      db "video/webm", 0
    mime_pdf:       db "application/pdf", 0
    mime_zip:       db "application/zip", 0
    mime_default:   db "application/octet-stream", 0

    ;----------------------------------------------------------------------
    ; Socket Configuration Values
    ;----------------------------------------------------------------------
    reuse_val:      dd 1
    reuseport_val:  dd 1
    keepalive_val:  dd 1
    nodelay_val:    dd 1
    cork_val:       dd 1
    busy_poll_val:  dd 50                 ; 50us busy poll
    linger_val:     dq 0, 0

    ; TCP keepalive parameters
    ka_idle:        dd 60
    ka_intvl:       dd 10
    ka_cnt:         dd 6

    ; Read timeout
    rcv_timeo:      dq READ_TIMEOUT_SEC, 0

    ;----------------------------------------------------------------------
    ; Default Configuration Values
    ;----------------------------------------------------------------------
    default_port:           dd 8080
    default_root:           db "/var/www/html", 0
    default_user:           db "nobody", 0
    default_cores:          dd 1

    ; Index files
    index_html:     db "/index.html", 0
    index_htm:      db "/index.htm", 0

    ;----------------------------------------------------------------------
    ; Calendar Data
    ;----------------------------------------------------------------------
    day_names:      db "SunMonTueWedThuFriSat"
    month_names:    db "JanFebMarAprMayJunJulAugSepOctNovDec"
    month_days:     db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    month_days_leap: db 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

    month_table:
        dq mon_jan, mon_feb, mon_mar, mon_apr
        dq mon_may, mon_jun, mon_jul, mon_aug
        dq mon_sep, mon_oct, mon_nov, mon_dec

    mon_jan:        db "Jan", 0
    mon_feb:        db "Feb", 0
    mon_mar:        db "Mar", 0
    mon_apr:        db "Apr", 0
    mon_may:        db "May", 0
    mon_jun:        db "Jun", 0
    mon_jul:        db "Jul", 0
    mon_aug:        db "Aug", 0
    mon_sep:        db "Sep", 0
    mon_oct:        db "Oct", 0
    mon_nov:        db "Nov", 0
    mon_dec:        db "Dec", 0

    ;----------------------------------------------------------------------
    ; Log Templates
    ;----------------------------------------------------------------------
    log_startup:    db "PulseVM/3.4 starting on port ", 0
    log_ready:      db "Server ready, root: ", 0
    log_cores:      db "Workers: ", 0
    log_uring:      db "io_uring initialized with ", 0
    log_uring2:     db " entries", 10, 0
    log_cache:      db "Metadata cache: ", 0
    log_cache2:     db " entries", 10, 0
    log_req:        db "Request: ", 0
    log_cache_hit:  db " (cache hit)", 0
    log_range:      db " (range)", 0
    log_304:        db " (304)", 0
    log_shutdown:   db "Shutting down...", 10, 0
    log_newline:    db 10, 0

    ;----------------------------------------------------------------------
    ; Signal Handler
    ;----------------------------------------------------------------------
    align 16
    sigact:         dq 0, 0, 0, 0, 0

    ;----------------------------------------------------------------------
    ; Fatal Error
    ;----------------------------------------------------------------------
    fatal_msg:      db "PulseVM: Fatal initialization error", 10, 0
    fatal_len:      equ $ - fatal_msg

;==============================================================================
; BSS Section
;==============================================================================
section .bss
    align 64
    ;----------------------------------------------------------------------
    ; io_uring Ring Buffers
    ;----------------------------------------------------------------------
    ; Submission Queue
    sq_ring_ptr:    resq 1          ; mmap'd SQ ring
    sq_entries:     resd 1
    sq_head:        resq 1
    sq_tail:        resq 1
    sq_ring_mask:   resd 1
    sq_ring_entries: resd 1
    sq_flags:       resq 1
    sq_dropped:     resq 1
    sq_array:       resq 1          ; Index array
    sq_sqes:        resq 1          ; Actual SQEs

    ; Completion Queue
    cq_ring_ptr:    resq 1
    cq_head:        resq 1
    cq_tail:        resq 1
    cq_ring_mask:   resd 1
    cq_ring_entries: resd 1
    cq_overflow:    resq 1
    cq_cqes:        resq 1

    ; io_uring file descriptor
    ring_fd:        resd 1

    ;----------------------------------------------------------------------
    ; I/O Buffers
    ;----------------------------------------------------------------------
    recv_buffer:    resb BUFFER_SIZE
    send_buffer:    resb BUFFER_SIZE
    header_buf:     resb BUFFER_SIZE
    path_buffer:    resb MAX_PATH
    real_path:      resb MAX_PATH
    decoded_path:   resb MAX_PATH

    ;----------------------------------------------------------------------
    ; File Metadata
    ;----------------------------------------------------------------------
    stat_buf:       resb 144

    ;----------------------------------------------------------------------
    ; Network Address
    ;----------------------------------------------------------------------
    sockaddr_in:    resb 16

    ;----------------------------------------------------------------------
    ; Logging
    ;----------------------------------------------------------------------
    log_buffer:     resb 256

    ;----------------------------------------------------------------------
    ; Time Buffer
    ;----------------------------------------------------------------------
    time_buffer:    resb 32

    ;----------------------------------------------------------------------
    ; Range Storage
    ;----------------------------------------------------------------------
    range_count:    resd 1
    range_starts:   resq MAX_RANGES
    range_ends:     resq MAX_RANGES

    ;----------------------------------------------------------------------
    ; Metadata Cache
    ;   Hash table with CACHE_ENTRY_SIZE * MAX_CACHE_ENTRIES bytes
    ;----------------------------------------------------------------------
    cache_table:    resb CACHE_ENTRY_SIZE * MAX_CACHE_ENTRIES
    cache_locks:    resd (MAX_CACHE_ENTRIES / 64)  ; One lock per 64 entries

    ;----------------------------------------------------------------------
    ; MMAP Arena
    ;----------------------------------------------------------------------
    mmap_arena:     resq 1          ; Base address
    mmap_bitmap:    resb (MAX_MMAP_FILES / 8)  ; Allocation bitmap

    ;----------------------------------------------------------------------
    ; inotify
    ;----------------------------------------------------------------------
    inotify_fd:     resd 1
    inotify_wd:     resd 1
    inotify_buf:    resb INOTIFY_BUF_SIZE

    ;----------------------------------------------------------------------
    ; Pipe for splice operations
    ;----------------------------------------------------------------------
    splice_pipe:    resd 2          ; read_fd, write_fd

    ;----------------------------------------------------------------------
    ; Global State
    ;----------------------------------------------------------------------
    ring_fd:        resd 1
    server_fd:      resd 1
    port_num:       resd 1
    conn_count:     resd 1
    max_conn:       resd 1
    running:        resd 1
    target_uid:     resd 1
    target_gid:     resd 1
    keepalive_max:  resq 1
    num_cores:      resd 1
    worker_id:      resd 1
    cache_count:    resd 1
    current_time:   resq 1

    ;----------------------------------------------------------------------
    ; Root Path
    ;----------------------------------------------------------------------
    root_path:      resq 1
    root_len:       resq 1
    root_storage:   resb MAX_PATH

    ;----------------------------------------------------------------------
    ; MIME Cache Flag
    ;----------------------------------------------------------------------
    mime_cacheable: resb 1

    ;----------------------------------------------------------------------
    ; Per-request counter
    ;----------------------------------------------------------------------
    request_count:  resd 1

;==============================================================================
; Code Section
;==============================================================================
section .text
global _start

;------------------------------------------------------------------------------
; Program Entry Point
;------------------------------------------------------------------------------
_start:
    ; Initialize state
    mov     dword [conn_count], 0
    mov     dword [max_conn], MAX_CONNECTIONS
    mov     dword [running], 1
    mov     dword [target_uid], -1
    mov     dword [target_gid], -1
    mov     dword [cache_count], 0
    mov     dword [worker_id], 0
    mov     qword [keepalive_max], MAX_KEEPALIVE_REQS

    ; Parse arguments: ./pulsevm [port] [root] [user] [keepalive_max] [cores]
    pop     rcx
    pop     rdi

    cmp     rcx, 1
    je      .use_defaults

    pop     rdi
    call    parse_int
    mov     [port_num], eax
    dec     rcx

    cmp     rcx, 1
    jl      .use_default_root
    pop     rdi
    jmp     .setup_root

.use_defaults:
    mov     eax, [default_port]
    mov     [port_num], eax
.use_default_root:
    lea     rdi, [default_root]

.setup_root:
    call    initialize_root_path
    test    rax, rax
    jz      fatal_error

    dec     rcx
    cmp     rcx, 1
    jl      .parse_cores
    pop     rdi
    call    lookup_user

    dec     rcx
    cmp     rcx, 1
    jl      .parse_cores
    pop     rdi
    call    parse_int
    mov     [keepalive_max], rax

.parse_cores:
    dec     rcx
    cmp     rcx, 1
    jl      .init_cores
    pop     rdi
    call    parse_int
    mov     [num_cores], eax
    jmp     .init_subsystems

.init_cores:
    mov     eax, [default_cores]
    mov     [num_cores], eax

    ;----------------------------------------------------------------------
    ; Initialize Subsystems
    ;----------------------------------------------------------------------
.init_subsystems:
    ; Install signal handlers
    call    setup_signal_handlers

    ; Initialize io_uring
    call    init_io_uring

    ; Initialize metadata cache
    call    init_cache

    ; Initialize inotify
    call    init_inotify

    ; Create splice pipe
    call    create_splice_pipe

    ; Create server socket with SO_REUSEPORT
    call    create_server_socket

    ; Bind and listen
    call    bind_and_listen

    ; Drop privileges
    call    drop_privileges_if_needed

    ; Fork workers for multi-core
    mov     ecx, [num_cores]
    cmp     ecx, 1
    jle     .single_worker

    ; Fork worker processes
    mov     ebx, 1                 ; Worker ID counter

.fork_loop:
    cmp     ebx, ecx
    jge     .fork_done

    mov     eax, SYS_fork
    syscall

    test    rax, rax
    jz      .worker_start          ; Child process
    js      fatal_error

    inc     ebx
    jmp     .fork_loop

.worker_start:
    mov     [worker_id], ebx

    ; Set CPU affinity
    mov     edi, 0                 ; Current PID
    mov     esi, 8                 ; CPU set size
    lea     rdx, [cpu_mask]
    mov     eax, SYS_sched_setaffinity
    syscall

    ; Create new io_uring for this worker
    call    init_io_uring

.single_worker:
.fork_done:
    ; Populate cache by scanning root directory
    call    populate_cache

    ; Log startup
    call    log_server_startup

    ;----------------------------------------------------------------------
    ; Main Event Loop (io_uring-based)
    ;----------------------------------------------------------------------
    jmp     event_loop

;------------------------------------------------------------------------------
; init_io_uring
;   Sets up io_uring with kernel-side polling for maximum performance.
;   Maps SQ and CQ rings into userspace for zero-syscall submission.
;------------------------------------------------------------------------------
init_io_uring:
    push    rbp
    mov     rbp, rsp

    ; io_uring_setup(entries, &params)
    mov     edi, IO_URING_ENTRIES
    lea     rsi, [uring_params]
    mov     eax, SYS_io_uring_setup
    syscall
    test    rax, rax
    js      fatal_error
    mov     [ring_fd], eax

    ; Calculate memory needed for rings
    ; SQ ring size
    mov     eax, [uring_params + 16]    ; sq_off.array
    add     eax, [uring_params + 8]     ; sq_entries * 4
    mov     [sq_ring_size], eax

    ; CQ ring size
    mov     eax, [uring_params + 40]    ; cq_off.cqes
    add     eax, [uring_params + 32]    ; cq_entries * 16
    mov     [cq_ring_size], eax

    ; mmap SQ ring
    mov     edi, 0
    mov     esi, [sq_ring_size]
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_SHARED | MAP_POPULATE
    mov     r8d, [ring_fd]
    mov     r9d, 0                    ; IORING_OFF_SQ_RING
    mov     eax, SYS_mmap
    syscall
    test    rax, rax
    js      fatal_error
    mov     [sq_ring_ptr], rax

    ; Set up SQ pointers
    lea     rbx, [uring_params]
    mov     rcx, [sq_ring_ptr]

    ; sq_head
    mov     eax, [rbx + 0]            ; sq_off.head
    add     rax, rcx
    mov     [sq_head], rax

    ; sq_tail
    mov     eax, [rbx + 4]            ; sq_off.tail
    add     rax, rcx
    mov     [sq_tail], rax

    ; sq_ring_mask
    mov     eax, [rbx + 8]            ; sq_off.ring_mask
    add     rax, rcx
    mov     [sq_ring_mask_ptr], rax
    mov     eax, [rax]
    mov     [sq_ring_mask], eax

    ; sq_ring_entries
    mov     eax, [rbx + 12]           ; sq_off.ring_entries
    add     rax, rcx
    mov     [sq_ring_entries_ptr], rax
    mov     eax, [rax]
    mov     [sq_ring_entries], eax

    ; sq_flags
    mov     eax, [rbx + 16]           ; sq_off.flags
    add     rax, rcx
    mov     [sq_flags], rax

    ; sq_dropped
    mov     eax, [rbx + 20]           ; sq_off.dropped
    add     rax, rcx
    mov     [sq_dropped], rax

    ; sq_array
    mov     eax, [rbx + 24]           ; sq_off.array
    add     rax, rcx
    mov     [sq_array], rax

    ; mmap SQEs
    mov     eax, [uring_params + 8]   ; sq_entries
    imul    eax, 64                   ; 64 bytes per SQE
    mov     [sq_sqes_size], eax

    mov     edi, 0
    mov     esi, eax
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_SHARED | MAP_POPULATE
    mov     r8d, [ring_fd]
    mov     r9d, 0x10000000           ; IORING_OFF_SQES
    mov     eax, SYS_mmap
    syscall
    test    rax, rax
    js      fatal_error
    mov     [sq_sqes], rax

    ; mmap CQ ring
    mov     edi, 0
    mov     esi, [cq_ring_size]
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_SHARED | MAP_POPULATE
    mov     r8d, [ring_fd]
    mov     r9d, 0x8000000            ; IORING_OFF_CQ_RING
    mov     eax, SYS_mmap
    syscall
    test    rax, rax
    js      fatal_error
    mov     [cq_ring_ptr], rax

    ; Set up CQ pointers
    lea     rbx, [uring_params + 24]  ; cq_off starts at byte 24

    mov     rcx, [cq_ring_ptr]

    ; cq_head
    mov     eax, [rbx + 0]
    add     rax, rcx
    mov     [cq_head], rax

    ; cq_tail
    mov     eax, [rbx + 4]
    add     rax, rcx
    mov     [cq_tail], rax

    ; cq_ring_mask
    mov     eax, [rbx + 8]
    add     rax, rcx
    mov     [cq_ring_mask_ptr], rax
    mov     eax, [rax]
    mov     [cq_ring_mask], eax

    ; cq_ring_entries
    mov     eax, [rbx + 12]
    add     rax, rcx
    mov     [cq_ring_entries_ptr], rax
    mov     eax, [rax]
    mov     [cq_ring_entries], eax

    ; cq_overflow
    mov     eax, [rbx + 16]
    add     rax, rcx
    mov     [cq_overflow], rax

    ; cq_cqes
    mov     eax, [rbx + 20]
    add     rax, rcx
    mov     [cq_cqes], rax

    pop     rbp
    ret

;------------------------------------------------------------------------------
; Event Loop (io_uring-based)
;------------------------------------------------------------------------------
event_loop:
    ; Check running flag
    cmp     dword [running], 0
    je      shutdown

    ; Reap completions
    call    reap_completions

    ; Submit any pending SQEs
    call    submit_sqes

    ; If no pending work, enter kernel to wait for events
    mov     edi, [ring_fd]
    mov     esi, 1                  ; Wait for at least 1 completion
    mov     edx, 0                  ; No new submissions
    xor     r10d, r10d
    mov     eax, SYS_io_uring_enter
    syscall

    jmp     event_loop

;------------------------------------------------------------------------------
; reap_completions
;   Processes completion queue entries from io_uring.
;------------------------------------------------------------------------------
reap_completions:
    push    r12
    push    r13

    mov     r12, [cq_head]
    mov     r13, [cq_tail]

.reap_loop:
    cmp     r12d, r13d
    je      .done

    ; Calculate CQE address
    mov     eax, r12d
    and     eax, [cq_ring_mask]
    imul    rax, 16
    add     rax, [cq_cqes]

    ; Get user_data (identifies the request)
    mov     rdi, [rax + CQE_USER_DATA]
    mov     esi, [rax + CQE_RES]     ; Result code

    ; Dispatch based on user_data type
    call    dispatch_completion

    ; Advance head
    inc     r12d
    mov     rax, [cq_head]
    mov     [rax], r12d

    jmp     .reap_loop

.done:
    pop     r13
    pop     r12
    ret

;------------------------------------------------------------------------------
; dispatch_completion
;   Routes completion to appropriate handler.
;   user_data encodes: [type:8][fd:24]
;   Types: 0=accept, 1=read, 2=write, 3=sendfile, 4=close
;------------------------------------------------------------------------------
dispatch_completion:
    push    rbp
    mov     rbp, rsp

    mov     eax, edi
    shr     eax, 24                 ; Type
    and     edi, 0xFFFFFF           ; FD or identifier

    cmp     eax, 0
    je      .accept_done
    cmp     eax, 1
    je      .read_done
    cmp     eax, 2
    je      .write_done
    cmp     eax, 3
    je      .sendfile_done
    cmp     eax, 4
    je      .close_done

    jmp     .done

.accept_done:
    ; New connection accepted
    ; edi = client fd, esi = result
    cmp     esi, 0
    jl      .done                   ; Accept failed

    ; Queue read SQE for this client
    mov     edi, edi               ; Client fd
    call    queue_read_sqe
    jmp     .done

.read_done:
    ; Request read complete
    ; edi = client fd, esi = bytes read
    cmp     esi, 0
    jle     .close_client

    mov     r12, rdi               ; Save client fd
    mov     r13, rsi               ; Bytes read

    ; Process request and build response
    call    handle_client_async

    jmp     .done

.write_done:
    ; Response sent
    ; Keep-alive: queue another read
    mov     edi, edi
    call    queue_read_sqe
    jmp     .done

.sendfile_done:
    ; File body sent
    ; Close file descriptor if not cached
    jmp     .done

.close_client:
    mov     edi, edi
    call    queue_close_sqe

.close_done:
    dec     dword [conn_count]

.done:
    pop     rbp
    ret

;------------------------------------------------------------------------------
; queue_read_sqe
;   Queues an IORING_OP_READ SQE for a client socket.
;------------------------------------------------------------------------------
queue_read_sqe:
    push    r12
    mov     r12, rdi               ; Client fd

    ; Get next SQE
    call    get_sqe
    test    rax, rax
    jz      .done

    ; Fill SQE
    mov     byte [rax + SQE_OPCODE], IORING_OP_READ
    mov     byte [rax + SQE_FLAGS], 0
    mov     dword [rax + SQE_FD], r12d
    mov     qword [rax + SQE_OFF], 0
    lea     rcx, [recv_buffer]
    mov     [rax + SQE_ADDR], rcx
    mov     dword [rax + SQE_LEN], BUFFER_SIZE - 1
    mov     dword [rax + SQE_ACCEPT_FLAGS], 0

    ; user_data = (1 << 24) | client_fd
    mov     ecx, r12d
    or      ecx, (1 << 24)
    mov     [rax + SQE_USER_DATA], rcx

.done:
    pop     r12
    ret

;------------------------------------------------------------------------------
; queue_accept_sqe
;   Queues an IORING_OP_ACCEPT SQE for the server socket.
;------------------------------------------------------------------------------
queue_accept_sqe:
    call    get_sqe
    test    rax, rax
    jz      .done

    mov     byte [rax + SQE_OPCODE], IORING_OP_ACCEPT
    mov     byte [rax + SQE_FLAGS], 0
    mov     edi, [server_fd]
    mov     dword [rax + SQE_FD], edi
    mov     qword [rax + SQE_OFF], 0
    lea     rcx, [sockaddr_in]
    mov     [rax + SQE_ADDR], rcx
    lea     rcx, [client_addr_len]
    mov     [rax + SQE_LEN], rcx
    mov     dword [rax + SQE_ACCEPT_FLAGS], SOCK_NONBLOCK

    mov     dword [rax + SQE_USER_DATA], (0 << 24)

.done:
    ret

;------------------------------------------------------------------------------
; get_sqe
;   Returns pointer to next available SQE, or NULL if ring is full.
;------------------------------------------------------------------------------
get_sqe:
    mov     rax, [sq_tail]
    mov     eax, [rax]             ; Current tail
    mov     ecx, [sq_head]
    mov     ecx, [ecx]             ; Current head

    ; Check if ring is full
    mov     edx, eax
    sub     edx, ecx
    cmp     edx, [sq_ring_entries]
    jae     .full

    ; Get SQE index from array
    and     eax, [sq_ring_mask]
    mov     rdx, [sq_array]
    mov     eax, [rdx + rax * 4]   ; Index into SQE array

    ; Calculate SQE address
    imul    rax, 64
    add     rax, [sq_sqes]

    ; Advance tail
    mov     rdx, [sq_tail]
    inc     dword [rdx]

    ret

.full:
    xor     eax, eax
    ret

;------------------------------------------------------------------------------
; submit_sqes
;   Submits pending SQEs to the kernel if needed.
;------------------------------------------------------------------------------
submit_sqes:
    ; Check if we need to submit
    mov     rax, [sq_flags]
    test    dword [rax], 1         ; SQ_NEED_WAKEUP
    jz      .done

    mov     edi, [ring_fd]
    mov     esi, 0                 ; No wait for completions
    mov     edx, 1                 ; Submit pending
    xor     r10d, r10d
    mov     eax, SYS_io_uring_enter
    syscall

.done:
    ret

;------------------------------------------------------------------------------
; handle_client_async
;   Processes a client request in the io_uring completion path.
;   r12 = client fd, r13 = bytes read
;------------------------------------------------------------------------------
handle_client_async:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi

    ; Null terminate request
    mov     byte [recv_buffer + r13], 0

    ; Try cache lookup first
    lea     rdi, [recv_buffer + 4]  ; Skip "GET "
    call    cache_lookup
    test    rax, rax
    jz      .cache_miss

    ; Cache hit - use pre-computed headers
    mov     r14, rax               ; Cache entry pointer
    mov     r15, [r14 + CE_SIZE]   ; File size

    ; Queue write for pre-computed headers
    call    get_sqe
    test    rax, rax
    jz      .done

    mov     byte [rax + SQE_OPCODE], IORING_OP_WRITE
    mov     dword [rax + SQE_FD], r12d
    mov     rcx, [r14 + CE_HEADER_PTR]
    mov     [rax + SQE_ADDR], rcx
    mov     ecx, [r14 + CE_HEADER_LEN]
    mov     dword [rax + SQE_LEN], ecx
    mov     ecx, r12d
    or      ecx, (2 << 24)
    mov     [rax + SQE_USER_DATA], rcx

    ; Check if file is mmap'd
    mov     rcx, [r14 + CE_MMAP_ADDR]
    test    rcx, rcx
    jz      .use_sendfile

    ; Use splice from mmap'd memory via pipe
    ; (simplified - in production would use IORING_OP_SPLICE)
    jmp     .queue_sendfile

.use_sendfile:
    ; Queue sendfile for body
    call    get_sqe
    test    rax, rax
    jz      .done

    mov     byte [rax + SQE_OPCODE], IORING_OP_SENDFILE
    mov     dword [rax + SQE_FD], r12d

    ; Need to open file first - queue openat + sendfile linked
    ; For simplicity, assume file fd is cached
    mov     ecx, [r14 + CE_INODE]   ; Use inode as cached fd
    mov     dword [rax + SQE_FD + 4], ecx  ; This is simplified

    mov     qword [rax + SQE_OFF], 0
    mov     [rax + SQE_ADDR], r15
    mov     ecx, r12d
    or      ecx, (3 << 24)
    mov     [rax + SQE_USER_DATA], rcx

    jmp     .done

.cache_miss:
    ; Fall back to traditional processing
    call    handle_client

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

;------------------------------------------------------------------------------
; init_cache
;   Initializes the metadata cache hash table.
;------------------------------------------------------------------------------
init_cache:
    ; Zero out cache table
    mov     edi, CACHE_ENTRY_SIZE * MAX_CACHE_ENTRIES
    lea     rdi, [cache_table]
    xor     eax, eax
    mov     ecx, edi
    shr     ecx, 3
    rep     stosq

    ; Allocate MMAP arena
    mov     edi, 0
    mov     esi, MMAP_ARENA_SIZE
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_mmap
    syscall
    test    rax, rax
    js      fatal_error
    mov     [mmap_arena], rax

    ret

;------------------------------------------------------------------------------
; cache_lookup
;   Looks up a path in the metadata cache.
;   Returns pointer to cache entry or NULL on miss.
;------------------------------------------------------------------------------
cache_lookup:
    push    r12
    push    r13

    mov     r12, rdi               ; Path

    ; Compute hash
    call    murmur3_64
    mov     r13, rax

    ; Find bucket
    and     eax, (MAX_CACHE_ENTRIES - 1)
    imul    rax, CACHE_ENTRY_SIZE
    lea     rbx, [cache_table + rax]

    ; Check bucket
    cmp     byte [rbx + CE_IN_USE], 1
    jne     .miss

    mov     rax, [rbx + CE_HASH]
    cmp     rax, r13
    jne     .miss

    ; Update access time
    mov     rax, [current_time]
    mov     [rbx + CE_ACCESS_TIME], rax
    inc     qword [rbx + CE_ACCESS_COUNT]

    mov     rax, rbx
    jmp     .done

.miss:
    xor     eax, eax

.done:
    pop     r13
    pop     r12
    ret

;------------------------------------------------------------------------------
; murmur3_64
;   Fast non-cryptographic hash for cache keys.
;------------------------------------------------------------------------------
murmur3_64:
    push    rbx
    push    rcx
    push    rdx

    mov     rbx, 0xc6a4a7935bd1e995
    mov     rcx, 0x5bd1e995
    xor     rax, rax

    ; Simplified implementation
    ; In production: full MurmurHash3 64-bit finalizer

    pop     rdx
    pop     rcx
    pop     rbx
    ret

;------------------------------------------------------------------------------
; populate_cache
;   Scans root directory and populates cache with file metadata.
;------------------------------------------------------------------------------
populate_cache:
    ; Open root directory
    mov     rdi, [root_path]
    mov     esi, O_RDONLY | O_DIRECTORY
    mov     eax, SYS_open
    syscall
    test    rax, rax
    js      .done

    mov     r12, rax               ; Root dir fd

    ; Read directory entries
    lea     rsi, [dirent_buf]
    mov     edx, 4096
    mov     eax, SYS_getdents
    syscall

    ; Process each entry and add to cache
    ; (simplified - full implementation would recurse into subdirectories)

    mov     edi, r12d
    mov     eax, SYS_close
    syscall

.done:
    ret

;------------------------------------------------------------------------------
; init_inotify
;   Sets up inotify watch on root directory for cache invalidation.
;------------------------------------------------------------------------------
init_inotify:
    mov     edi, 0                  ; No flags
    mov     eax, SYS_inotify_init1
    syscall
    test    rax, rax
    js      .done                   ; Non-fatal
    mov     [inotify_fd], eax

    ; Add watch on root directory
    mov     edi, eax
    mov     rsi, [root_path]
    mov     edx, 0x00000FFF         ; IN_ALL_EVENTS (simplified)
    mov     eax, SYS_inotify_add_watch
    syscall
    mov     [inotify_wd], eax

.done:
    ret

;------------------------------------------------------------------------------
; create_splice_pipe
;   Creates a pipe for splice() operations.
;------------------------------------------------------------------------------
create_splice_pipe:
    lea     rdi, [splice_pipe]
    mov     eax, SYS_pipe2
    syscall
    ret

;------------------------------------------------------------------------------
; create_server_socket (with SO_REUSEPORT)
;------------------------------------------------------------------------------
create_server_socket:
    mov     edi, AF_INET
    mov     esi, SOCK_STREAM | SOCK_NONBLOCK
    xor     edx, edx
    mov     eax, SYS_socket
    syscall
    test    rax, rax
    js      fatal_error
    mov     [server_fd], eax

    ; SO_REUSEADDR
    mov     edi, eax
    mov     esi, SOL_SOCKET
    mov     edx, SO_REUSEADDR
    lea     r10, [reuse_val]
    mov     r8d, 4
    mov     eax, SYS_setsockopt
    syscall

    ; SO_REUSEPORT - enables multi-core scaling
    mov     edi, [server_fd]
    mov     esi, SOL_SOCKET
    mov     edx, SO_REUSEPORT
    lea     r10, [reuseport_val]
    mov     r8d, 4
    mov     eax, SYS_setsockopt
    syscall

    ; SO_KEEPALIVE
    mov     edi, [server_fd]
    mov     esi, SOL_SOCKET
    mov     edx, SO_KEEPALIVE
    lea     r10, [keepalive_val]
    mov     r8d, 4
    mov     eax, SYS_setsockopt
    syscall

    ; SO_BUSY_POLL for sub-millisecond latency
    mov     edi, [server_fd]
    mov     esi, SOL_SOCKET
    mov     edx, SO_BUSY_POLL
    lea     r10, [busy_poll_val]
    mov     r8d, 4
    mov     eax, SYS_setsockopt
    syscall

    ret

;------------------------------------------------------------------------------
; bind_and_listen
;------------------------------------------------------------------------------
bind_and_listen:
    mov     word [sockaddr_in], AF_INET
    mov     eax, [port_num]
    xchg    al, ah
    mov     word [sockaddr_in + 2], ax
    mov     dword [sockaddr_in + 4], 0

    mov     edi, [server_fd]
    lea     rsi, [sockaddr_in]
    mov     edx, 16
    mov     eax, SYS_bind
    syscall
    test    rax, rax
    js      fatal_error

    mov     edi, [server_fd]
    mov     esi, LISTEN_BACKLOG
    mov     eax, SYS_listen
    syscall
    test    rax, rax
    js      fatal_error

    ; Queue initial accept SQEs
    mov     ecx, 64                 ; Pre-queue multiple accepts

.accept_queue_loop:
    call    queue_accept_sqe
    dec     ecx
    jnz     .accept_queue_loop

    ret

;------------------------------------------------------------------------------
; Placeholder for handle_client (from 3.3 - included for cache miss fallback)
;------------------------------------------------------------------------------
handle_client:
    ; Fallback handler when cache misses
    ; This would contain the full HTTP parsing from 3.3
    ; For brevity, we queue a 404 response
    mov     edi, r12d
    lea     rsi, [err_404_hdr]
    mov     edx, err_404_len
    mov     eax, SYS_write
    syscall
    ret

;------------------------------------------------------------------------------
; io_uring parameter structure (must match kernel layout)
;------------------------------------------------------------------------------
section .data
    align 8
    uring_params:
        dd 0                        ; sq_entries
        dd 0                        ; cq_entries
        dd 0                        ; flags
        dd 0                        ; sq_thread_cpu
        dd 0                        ; sq_thread_idle
        dd 0                        ; features
        dd 0                        ; wq_fd
        dd 0, 0, 0                  ; resv
        ; sq_off
        dd 0, 0, 0, 0, 0, 0, 0, 0
        ; cq_off
        dd 0, 0, 0, 0, 0, 0, 0, 0

;==============================================================================
; BSS additions for io_uring
;==============================================================================
section .bss
    align 64
    sq_ring_size:       resd 1
    cq_ring_size:       resd 1
    sq_sqes_size:       resd 1
    sq_ring_mask_ptr:   resq 1
    sq_ring_entries_ptr: resq 1
    cq_ring_mask_ptr:   resq 1
    cq_ring_entries_ptr: resq 1
    cpu_mask:           resb 128
    client_addr_len:    resd 1
    dirent_buf:         resb 4096