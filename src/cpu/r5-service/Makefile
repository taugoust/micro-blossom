CC ?= armr5-none-eabi-gcc
BUILD_DIR ?= build
COYOTE_ROOT ?= ../../../../coyote-fork
PROVIDER_DIR := $(COYOTE_ROOT)/sw/firmware/coprocessor

ARCH_FLAGS := -mcpu=cortex-r5 -marm -mabi=aapcs -mfloat-abi=soft -mlittle-endian -mno-unaligned-access
COMMON_FLAGS := $(ARCH_FLAGS) -Os -g -ffreestanding -fno-builtin -fno-common \
	-ffunction-sections -fdata-sections -fno-stack-protector -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables -fdebug-prefix-map=$(CURDIR)=. \
	-Wall -Wextra -Werror -I$(PROVIDER_DIR)
CFLAGS := $(COMMON_FLAGS) -std=c11 $(EXTRA_CFLAGS)
ASFLAGS := $(COMMON_FLAGS)
LDFLAGS := $(ARCH_FLAGS) -nostdlib -nostartfiles -nodefaultlibs -static -no-pie \
	-Wl,-T,linker.ld -Wl,-e,_start -Wl,--gc-sections -Wl,--no-undefined \
	-Wl,--build-id=none -Wl,--fatal-warnings -Wl,--cref -Wl,-Map,$(BUILD_DIR)/r5.map
OBJECTS := $(BUILD_DIR)/provider.o $(BUILD_DIR)/provider_transport_r5.o \
	$(BUILD_DIR)/service.o $(BUILD_DIR)/startup.o

.PHONY: all clean
all: $(BUILD_DIR)/r5.elf
$(BUILD_DIR):
	mkdir -p $@
$(BUILD_DIR)/provider.o: $(PROVIDER_DIR)/provider.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/provider_transport_r5.o: $(PROVIDER_DIR)/provider_transport_r5.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/service.o: service.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/startup.o: startup.S | $(BUILD_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@
$(BUILD_DIR)/r5.elf: $(OBJECTS) linker.ld
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@
clean:
	rm -rf $(BUILD_DIR)
