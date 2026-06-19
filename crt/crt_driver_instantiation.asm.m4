dnl TS Tracker -- intentionally empty crt0 driver-instantiation file.
dnl
dnl The tracker uses no C stdio at all: it prints via a raw RST $10 thunk
dnl (putch in ts_io.c) and reads the keyboard via IN (read_row). So we
dnl instantiate NO stdin/stdout/stderr file drivers here, which drops the
dnl ~3.1 KB of unused terminal/console/inkey/fcntl driver code the default
dnl crt0 would otherwise link.
dnl
dnl Activated by -pragma-define:CRT_INCLUDE_DRIVER_INSTANTIATION=1 plus
dnl -Cm-Icrt in the tracker build (see Makefile). Boot-critical crt0 init
dnl (SP/IM/DI-EI/data+bss copy/exit) is independent of this file and is kept.
dnl
dnl WARNING: with no drivers instantiated, any C stdio call (printf/putchar/
dnl fputc/...) would crash. The tracker must keep printing only via putch.
