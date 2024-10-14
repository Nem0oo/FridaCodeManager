#import <Foundation/Foundation.h>
#import <libgen.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import "Dylibify.h"

static uint32_t rnd32(uint32_t v, uint32_t r) {
    r--;
    return (v + r) & ~r;
}

static void insertDylibCommand(const char *path, struct mach_header_64 *header) {
    char *name = basename((char *)path);
    struct dylib_command *dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (void *)header+header->sizeofcmds);
    dylib->cmd = LC_ID_DYLIB;
    dylib->cmdsize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(name) + 1, 8);
    dylib->dylib.name.offset = sizeof(struct dylib_command);
    dylib->dylib.compatibility_version = 0x10000;
    dylib->dylib.current_version = 0x10000;
    dylib->dylib.timestamp = 2;
    strncpy((void *)dylib + dylib->dylib.name.offset, name, strlen(name));
    header->ncmds++;
    header->sizeofcmds += dylib->cmdsize;
}

static void patchExecSlice(const char *path, struct mach_header_64 *header) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);

    // Literally convert an executable to a dylib
    if (header->magic == MH_MAGIC_64) {
        //assert(header->flags & MH_PIE);
        header->filetype = MH_DYLIB;
        header->flags &= ~MH_PIE;
    }

    // Add LC_ID_DYLIB
    BOOL hasDylibCommand = NO;
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds > 0; i++) {
        if(command->cmd == LC_ID_DYLIB) {
            hasDylibCommand = YES;
            break;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    if (!hasDylibCommand) {
        insertDylibCommand(path, header);
    }

    // Patch __PAGEZERO to map just a single zero page, fixing "out of address space"
    struct segment_command_64 *seg = (struct segment_command_64 *)imageHeaderPtr;
    assert(seg->cmd == LC_SEGMENT_64);
    if (seg->vmaddr == 0) {
        assert(seg->vmsize == 0x100000000);
        seg->vmaddr = 0x100000000 - 0x4000;
        seg->vmsize = 0x4000;
    }
}

void Dylibify(NSString* ExecutablePath) {
    const char* path = (const char*)ExecutablePath.UTF8String;
    int fd = open(path, O_RDWR, (mode_t)0600);
    struct stat s;
    fstat(fd, &s);
    void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM) {
        // Find compatible slice
        struct fat_header *header = (struct fat_header *)map;
        struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
        for (int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            if (OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64) {
                patchExecSlice(path, (struct mach_header_64 *)(map + OSSwapInt32(arch->offset)));
            }
            arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64) {
        patchExecSlice(path, (struct mach_header_64 *)map);
    } else {
        printf("Error: 32-bit app is not supported\n");
    }
    msync(map, s.st_size, MS_SYNC);
    munmap(map, s.st_size);
    close(fd);
}

int main(int argc, char *argv[]) {
    if(argc > 1) {
        Dylibify([NSString stringWithFormat:@"%s",argv[1]]);
    } else {
        printf("Usage: %s <path>\n", argv[0]);
    }

    return 0;
}
