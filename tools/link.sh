#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The PS5 link of Cemu's executable: tools/ps5.cmake makes this CMake's link rule, which calls
#
#   tools/link.sh OUTPUT [link flags] OBJECTS... LIBRARIES...
#
# It links as PS5_Vulkan links a RADV title (its tools/build-radv-title.sh): PS5_Vulkan's native
# CRT and C++ runtime, Cemu's and the port's objects and archives, RADV linked whole with its
# platform layer from the payload SDK fork (PS5_Vulkan's tools/radv-link.sh, sourced as is), the
# AGC link stubs, and the SDK's system module stubs, with prospero-lld into OUTPUT, a PIE ELF that
# tools/package.sh converts into eboot.bin.
#
# RADV and the SDK fork it was built with (tools/build-radv.sh): RADV_ARCHIVE and RADV_SDK, by
# default the build with patches/mesa in .deps/PS5_Vulkan/.deps/native/radv-ps5cemu and the SDK
# PS5_Vulkan's recipe set up. OUTPUT.radv names the archive linked (env.sh's ps5cemu_radv_stamp).
# Without them, the link fails, unless PS5CEMU_LINK_CHECK=1: then a stand-in that has no GPU takes
# RADV's place, which checks that everything else links, and OUTPUT.linkcheck marks the result as
# not an app.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"
vulkan=$PS5CEMU_ROOT/.deps/PS5_Vulkan
radv_archive=$PS5CEMU_RADV_ARCHIVE
radv_sdk=${RADV_SDK:-$vulkan/.deps/native/ps5-payload-sdk}
work=$PS5CEMU_BUILD/link
output=$1
shift

# CMake's link line, as prospero-lld takes it: the compiler driver's options go, -Wl, ones are
# unwrapped, and the system libraries are the SDK's module stubs, linked below.
inputs=()
for argument in "$@"; do
    case $argument in
        -Xlinker | -pthread | -lpthread | -ldl | -lrt | -lm | -rdynamic | -fPIC | -fPIE | -pie) ;;
        -O* | -g* | -m* | -f* | --target=* | -isysroot* | -isystem* | -D*) ;;
        -Wl,*) IFS=, read -r -a flags <<<"${argument#-Wl,}" && inputs+=("${flags[@]}") ;;
        *) inputs+=("$argument") ;;
    esac
done

mkdir -p "$work"
cc() { clang-18 -target x86_64-sie-ps5 -isysroot "$PS5_PAYLOAD_SDK" -isystem "$PS5_PAYLOAD_SDK/target/include/c++/v1" \
    -isystem "$PS5_PAYLOAD_SDK/target/include" -fno-stack-protector -fno-plt -femulated-tls \
    -fvisibility-nodllstorageclass=default "$@"; }
for name in app_crt app_cpp_runtime; do
    object=$work/$name.o
    if [[ ! -f $object || $vulkan/tooling/native/$name.cpp -nt $object ]]; then
        cc -std=c++20 -O2 -fno-exceptions -fno-rtti -ffunction-sections -fdata-sections \
            -c "$vulkan/tooling/native/$name.cpp" -o "$object"
    fi
done

rm -f "$output.linkcheck"
if [[ -f $radv_archive && -f $radv_sdk/target/lib/libps5platform.a ]]; then
    sdk=$radv_sdk
    # AGC comes from system modules; these link stubs only name the imports (as build-radv-title.sh)
    for stub in libSceAgc:agc_canary_link_stub libSceAgcDriver:agc_driver_canary_link_stub; do
        library=${stub%%:*} source=$vulkan/vendor/ps5/sdk/stubs/${stub#*:}.c
        if [[ ! -f $work/$library.so || $source -nt $work/$library.so || ${BASH_SOURCE[0]} -nt $work/$library.so ]]; then
            # exported as the PS5 target exports only with its dllstorageclass default
            clang-18 -target x86_64-sie-ps5 -isysroot "$sdk" -isystem "$sdk/target/include" -std=c11 -O2 -fPIC \
                -fvisibility-nodllstorageclass=default -c "$source" -o "$work/$library.o"
            "$sdk/bin/prospero-lld" --shared -soname "$library.prx" -o "$work/$library.so" "$work/$library.o"
        fi
    done
    # The recipe finds Clang's builtins through the compiler's resource directory; here they are
    # compiler-rt's emulated TLS (tools/build-deps.sh).
    printf '#!/bin/sh\necho %q\n' "$PS5CEMU_SYSROOT/clang-rt" >"$work/clang"
    chmod +x "$work/clang"
    # shellcheck source=/dev/null
    source "$vulkan/tools/radv-link.sh"
    PS5_CLANG=$work/clang radv_link_recipe "$vulkan" "$sdk" "$radv_archive"
    # Mesa's clock for the driver: clock_gettime, a system call of about 20 us on the console,
    # read around every submission and on every turn of its GPU waits; port/ps5/driver_clock.cpp
    # answers it from the TSC instead
    radv_link_flags+=(--wrap=os_time_get_nano)
    # fmt's prints to a FILE, which write into the FILE's own buffer through a layout the console's
    # stderr does not hold: port/ps5/crash.cpp's format apart, and send stderr's to the boot log
    for name in _ZN3fmt3v126vprintEP7__sFILENS0_17basic_string_viewIcEENS0_17basic_format_argsINS0_7contextEEE \
        _ZN3fmt3v1215vprint_bufferedEP7__sFILENS0_17basic_string_viewIcEENS0_17basic_format_argsINS0_7contextEEE \
        _ZN3fmt3v128vprintlnEP7__sFILENS0_17basic_string_viewIcEENS0_17basic_format_argsINS0_7contextEEE; do
        radv_link_flags+=("--wrap=$name")
    done
    # access and the directory calls are bound to the platform layer's with --defsym, which a --wrap
    # cannot come before: they are bound to port/ps5/netfs_files.cpp's instead, which answers /net
    # paths and calls the platform's for every other (kept in the link by name)
    for index in "${!radv_link_flags[@]}"; do
        for name in access opendir readdir closedir; do
            if [[ ${radv_link_flags[index]} == "--defsym=$name=ps5_$name" ]]; then
                radv_link_flags[index]="--defsym=$name=ps5cemu_$name"
                radv_link_flags+=("--undefined=ps5_$name")
            fi
        done
    done
    # everything is linked in one group below, and lld takes no group inside another. The platform
    # layer's fclose and fflush wraps (its open_memstream) are renamed ps5_memstream_fclose and
    # ps5_memstream_fflush in a copy of its archive: port/ps5/netfs_files.cpp wraps the two for /net
    # files and calls these for every other FILE. Its pthread_create wrap (a thread's stack) is renamed
    # ps5_platform_pthread_create, which port/ps5/threads.cpp's wrap calls once it has chosen the new
    # thread's CPUs (kept in the link by name: that wrap refers to it weakly).
    radv_link_flags+=(--undefined=ps5_platform_pthread_create)
    flattened=()
    for input in "${radv_link_inputs[@]}"; do
        if [[ $input == */libps5platform.a ]]; then
            if [[ ! -f $work/libps5platform-netfs.a || $input -nt $work/libps5platform-netfs.a || ${BASH_SOURCE[0]} -nt $work/libps5platform-netfs.a ]]; then
                llvm-objcopy-18 --redefine-sym=__wrap_fclose=ps5_memstream_fclose --redefine-sym=__wrap_fflush=ps5_memstream_fflush \
                    --redefine-sym=__wrap_pthread_create=ps5_platform_pthread_create \
                    "$input" "$work/libps5platform-netfs.a"
            fi
            input=$work/libps5platform-netfs.a
        fi
        [[ $input == --start-group || $input == --end-group ]] || flattened+=("$input")
    done
    radv_link_inputs=("${flattened[@]}")
    stubs=("$work/libSceAgc.so" "$work/libSceAgcDriver.so")
    # libc's allocator onto the title heap with a per-thread cache (port/ps5/heap_wrap.c): an object
    # ahead of the group defines every wrap the platform library's heap_wrap.o would, so that one
    # stays out
    heap_wrap=$PS5CEMU_ROOT/port/ps5/heap_wrap.c
    if [[ ! -f $work/heap_wrap.o || $heap_wrap -nt $work/heap_wrap.o || ${BASH_SOURCE[0]} -nt $work/heap_wrap.o ]]; then
        clang-18 -target x86_64-sie-ps5 -isysroot "$sdk" -isystem "$sdk/target/include" -std=c11 -O2 -fPIC -march=znver2 \
            -fno-stack-protector -fno-plt -femulated-tls -ffunction-sections -fdata-sections \
            -fvisibility-nodllstorageclass=default -c "$heap_wrap" -o "$work/heap_wrap.o"
    fi
    objects=("$work/heap_wrap.o")
    check=0
    echo "==> [link] RADV: $radv_archive"
elif [[ ${PS5CEMU_LINK_CHECK:-0} == 1 ]]; then
    sdk=$PS5_PAYLOAD_SDK
    clang-18 -target x86_64-sie-ps5 -isysroot "$sdk" -isystem "$sdk/target/include" -std=c11 -O2 -fPIC \
        -c "$PS5CEMU_ROOT/tools/radv-stand-in.c" -o "$work/radv-stand-in.o"
    radv_linker_script=(-T "$vulkan/tooling/psbc/ps5-pie-unwind.ld" -L "$vulkan/tooling/native")
    radv_link_inputs=(-L "$sdk/target/lib" "$work/radv-stand-in.o" "$sdk/target/lib/libc++.a" "$sdk/target/lib/libc++abi.a"
        "$sdk/target/lib/libunwind.a" "$PS5CEMU_SYSROOT/clang-rt/lib/linux/libclang_rt.builtins-x86_64.a")
    radv_link_flags=()
    stubs=()
    objects=()
    check=1
    echo "==> [link] no RADV: checking the link with a stand-in driver (not an app)"
else
    echo "RADV is missing: $radv_archive, with the payload SDK fork $radv_sdk." >&2
    echo "Build it with tools/build-radv.sh (PS5_PAYLOAD_SDK_FORK=<the fork>), or name a build with" >&2
    echo "RADV_ARCHIVE and RADV_SDK. PS5CEMU_LINK_CHECK=1 checks the rest of the link without it." >&2
    exit 2
fi

# Optional hooks, weak and checked before use, that nothing on the console provides: as null they
# stay out of the imports, which must all name a system module. The SDK libc's dlfcn wrappers report
# no dynamic loader without theirs (as ProsperoEden links); zstd's are its tracing.
absent=()
for name in __dlopen __dlsym __dladdr __dlclose __dlerror ZSTD_trace_compress_begin ZSTD_trace_compress_end \
        ZSTD_trace_decompress_begin ZSTD_trace_decompress_end; do
    absent+=("--defsym=$name=0")
done
# RADV's platform layer has the real thread-local destructor registration; a link check has none
((check)) && absent+=(--defsym=__cxa_thread_atexit_impl=0)

# Network shares: the C library's file calls go through
# port/ps5/netfs_files.cpp, which answers those on /net paths and passes every other on after one check
netfs_wraps=()
for name in open read pread lseek close fstat stat lstat realpath fopen fclose fflush fread fwrite \
        fseek fseeko ftell ftello rewind feof ferror clearerr fgetc getc ungetc fgets fileno; do
    netfs_wraps+=("--wrap=$name")
done
# with no platform layer (a link check), access and the directory calls are wrapped too (above, the
# app's are bound by name)
if ((check)); then
    for name in access opendir readdir closedir; do
        netfs_wraps+=("--wrap=$name")
    done
fi

# fcntl (port/ps5/fcntl.cpp): the console refuses F_SETFD on a socket, which curl's connections need
netfs_wraps+=(--wrap=fcntl)

# The system modules a title imports from: all the SDK names, but the web process's (WebKit's POSIX
# layer and its libkernel, which a title does not load; the SDK's libc.a below has what they would
# have supplied, fnmatch) and the Mono runtime's.
modules=()
for module in "$sdk"/target/lib/*.so; do
    case ${module##*/} in libScePosixForWebKit.so | libkernel_web.so | libmonosgen-2.0.so) ;; *) modules+=("$module") ;; esac
done

# Mesa's dispatch tables name every entry point weakly, and those nothing defines must read as null
# rather than become imports, which the title converter would look for in the system modules: as
# PS5_Vulkan links its titles (its tools/check-vulkan-runtime.sh), with no dynamic linker (LLD 18 then
# leaves undefined weak symbols out of the dynamic symbol table) and, for later LLDs, explicitly.
# RADV goes first: its archive, linked whole, has zlib built in (Mesa's subproject), which then
# stands for the zlib pacbrew's libz.a would otherwise add a second time.
"$sdk/bin/prospero-lld" "${radv_linker_script[@]}" --eh-frame-hdr --no-dynamic-linker -z nodynamic-undefined-weak \
    "${radv_link_flags[@]}" "${netfs_wraps[@]}" "${absent[@]}" \
    --version-script "$vulkan/tooling/native/app-symbols.map" --exclude-libs=ALL --gc-sections \
    --error-limit=0 -Map="$output.map" -e _start -o "$output" \
    "$work/app_crt.o" "$work/app_cpp_runtime.o" "${objects[@]}" \
    --start-group "${radv_link_inputs[@]}" "${inputs[@]}" --end-group \
    "${stubs[@]}" --as-needed "${modules[@]}" \
    "$sdk/target/lib/libc.a" # what no module exports to a title and the platform layer does not bind (as ProsperoEden links)
if ((check)); then
    touch "$output.linkcheck"
    rm -f "$output.radv"
else
    ps5cemu_radv_stamp >"$output.radv"
fi
echo "==> [link] $output ($(stat -c %s "$output") bytes)"
