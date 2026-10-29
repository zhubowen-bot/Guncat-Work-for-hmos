// exec/elf.h — reading enough of an ELF header to decide how a program can be started.
//
// The exec service has one route for each way a program can run -- natively, through a
// loader in this process, or under an emulator -- and e_machine is what tells the two
// architecture-shaped ones apart. Only the header is read: the file itself belongs to
// whoever ends up running it.
#pragma once

#include <cstdint>
#include <string>

/* e_machine values worth naming here. EM_386 is not routed to anything yet; it is
 * spelled out because it is the field's best-known value and the numbering is easier to
 * trust written down than remembered. */
#define EM_386     3
#define EM_X86_64  62
#define EM_AARCH64 183

#if defined __aarch64__
#  define HOST_ARCH EM_AARCH64
#elif defined __x86_64__
#  define HOST_ARCH EM_X86_64
#else
#  error "no HOST_ARCH for this architecture: name it here, with the emulator objects it needs"
#endif

// Whether the file starts with the ELF magic. Deliberately only the magic: a file that
// claims to be ELF and then cannot be read as one should still be routed, so that the
// route can say what is wrong with it rather than leaving the client with a bare failure.
bool IsElfFile(const std::string& path);

// e_machine out of the header, or 0 when the file is not a readable little-endian ELF.
// One read answers both this and IsElfFile(), which is why the kind decision uses it.
uint16_t ElfMachine(const std::string& path);
