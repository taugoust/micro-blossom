CC ?= armr5-none-eabi-gcc
BUILD_DIR ?= build
COYOTE_ROOT ?= ../../../../coyote-fork
RUST_SERVICE_ARCHIVE ?=
PROVIDER_DIR := $(COYOTE_ROOT)/sw/firmware/coprocessor

ifneq ($(strip $(RUST_SERVICE_ARCHIVE)),)
RUST_SERVICE_HEADER := microblossom_rust_service.h
RUST_SERVICE_INPUT := $(RUST_SERVICE_ARCHIVE)
RUST_SERVICE_CFLAGS := -DMICROBLOSSOM_RUST_DECODER_LINKED=1
endif

ARCH_FLAGS := -mcpu=cortex-r5 -marm -mabi=aapcs -mfloat-abi=soft -mlittle-endian -mno-unaligned-access
COMMON_FLAGS := $(ARCH_FLAGS) -Os -g -ffreestanding -fno-builtin -fno-common \
	-ffunction-sections -fdata-sections -fstack-usage -fno-stack-protector -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables -Wa,--noexecstack \
	-fdebug-prefix-map=$(CURDIR)=. -Wall -Wextra -Werror -I. -I$(PROVIDER_DIR)
CFLAGS := $(COMMON_FLAGS) -std=c11 $(RUST_SERVICE_CFLAGS) $(EXTRA_CFLAGS)
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
$(BUILD_DIR)/service.o: service.c service.h microblossom_graph_contract.h qshell_abi_generated.h $(RUST_SERVICE_HEADER) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@
$(BUILD_DIR)/startup.o: startup.S | $(BUILD_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@
$(BUILD_DIR)/r5.elf: $(OBJECTS) $(RUST_SERVICE_INPUT) linker.ld
	$(CC) $(OBJECTS) $(RUST_SERVICE_INPUT) $(LDFLAGS) -o $@
clean:
	rm -rf $(BUILD_DIR)
