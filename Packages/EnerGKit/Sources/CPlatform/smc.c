#include "CPlatform.h"
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimit pLimit;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;   // 80 bytes

enum { kSMCUserClientSelector = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

static uint32_t fourcc(const char *k) {
    return ((uint32_t)k[0] << 24) | ((uint32_t)k[1] << 16) | ((uint32_t)k[2] << 8) | (uint32_t)k[3];
}

static kern_return_t call(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(c, kSMCUserClientSelector, in, sizeof(*in), out, &outSize);
}

static kern_return_t key_info(io_connect_t c, const char *key, SMCKeyInfo *info, uint8_t *smc_result) {
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    kern_return_t kr = call(c, &in, &out);
    *smc_result = out.result;
    *info = out.keyInfo;
    return kr;
}

kern_return_t smc_open(io_connect_t *out) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, out);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(io_connect_t conn) { IOServiceClose(conn); }

kern_return_t smc_read(io_connect_t c, const char *key, uint8_t *buf, uint32_t *size, uint8_t *smc_result) {
    if (strlen(key) != 4) return kIOReturnBadArgument;
    SMCKeyInfo info;
    kern_return_t kr = key_info(c, key, &info, smc_result);
    if (kr != KERN_SUCCESS || *smc_result != 0) return kr;
    if (info.dataSize > 32) return kIOReturnBadArgument;
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    kr = call(c, &in, &out);
    *smc_result = out.result;
    if (kr != KERN_SUCCESS || out.result != 0) return kr;
    memcpy(buf, out.bytes, info.dataSize);
    *size = info.dataSize;
    return KERN_SUCCESS;
}

kern_return_t smc_write(io_connect_t c, const char *key, const uint8_t *buf, uint32_t size, uint8_t *smc_result) {
    if (strlen(key) != 4 || size > 32) return kIOReturnBadArgument;
    SMCKeyInfo info;
    kern_return_t kr = key_info(c, key, &info, smc_result);
    if (kr != KERN_SUCCESS || *smc_result != 0) return kr;
    if (info.dataSize != size) return kIOReturnBadArgument;
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, buf, size);
    kr = call(c, &in, &out);
    *smc_result = out.result;
    return kr;
}
