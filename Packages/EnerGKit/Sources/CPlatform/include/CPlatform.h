#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

/// Opens the AppleSMC user client.
kern_return_t smc_open(io_connect_t *out);
void smc_close(io_connect_t conn);

/// Reads a 4-char key into buf (max 32 bytes). *size receives the key's size.
/// *smc_result receives the SMC status byte: 0 ok, 132 key not found.
kern_return_t smc_read(io_connect_t conn, const char *key, uint8_t *buf, uint32_t *size, uint8_t *smc_result);

/// Writes `size` bytes to a 4-char key. Requires root for most keys.
kern_return_t smc_write(io_connect_t conn, const char *key, const uint8_t *buf, uint32_t size, uint8_t *smc_result);

/// Native charge limit via private PowerUI.framework.
/// Return 0 on success, -1 framework/class missing, -2 the call failed.
int powerui_get_limit(uint8_t *out_limit, bool *out_enabled);
int powerui_set_limit(uint8_t limit);
int powerui_set_enabled(bool enabled);
