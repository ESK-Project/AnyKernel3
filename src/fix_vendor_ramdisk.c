/* Build with aarch64-linux-android21-clang -static -Oz -flto -ffunction-sections
 * -fdata-sections -Wl,--gc-sections -s -o tools/fix_vendor_ramdisk src/fix_vendor_ramdisk.c
 */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static uint32_t read_le32(const unsigned char *bytes)
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t align_page(uint64_t size, uint32_t page)
{
    return (size + page - 1) / page * page;
}

static int fix_vendor_ramdisk(int fd)
{
    unsigned char header[2128];
    unsigned char entry[108];

    if (pread(fd, header, sizeof(header), 0) != sizeof(header) ||
        memcmp(header, "VNDRBOOT", 8) || read_le32(header + 8) != 4)
        return 1;

    uint32_t page = read_le32(header + 12);
    uint32_t ramdisk_size = read_le32(header + 24);
    uint32_t dtb_size = read_le32(header + 2100);
    if (page < sizeof(header) || read_le32(header + 2112) != sizeof(entry) ||
        read_le32(header + 2116) != 1 || read_le32(header + 2120) != sizeof(entry))
        return 1;

    off_t table = page + align_page(ramdisk_size, page) + align_page(dtb_size, page);
    if (pread(fd, entry, sizeof(entry), table) != sizeof(entry) ||
        read_le32(entry + 4) != 0 || read_le32(entry + 8) != 1 ||
        read_le32(entry) >= ramdisk_size)
        return 1;

    return pwrite(fd, header + 24, sizeof(uint32_t), table) != sizeof(uint32_t);
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 1;
    int fd = open(argv[1], O_RDWR);
    if (fd < 0)
        return 1;
    int result = fix_vendor_ramdisk(fd);
    if (close(fd) != 0)
        return 1;
    return result;
}
