# pam_blitzkvm.so (arm64) and its test harness, which needs neither root
# nor sudo: `make -C remote/pam test`.

CC = /usr/bin/cc
CFLAGS = -arch arm64 -mmacosx-version-min=14.0 -std=c11 -D_DARWIN_C_SOURCE -O2 -Wall -Wextra -Werror
BUILD = build

.PHONY: all test clean

all: $(BUILD)/pam_blitzkvm.so

$(BUILD)/pam_blitzkvm.so: pam_blitzkvm.c
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -bundle -o $@ $< -lpam

$(BUILD)/pam_test: pam_test.c
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< -lpam

test: $(BUILD)/pam_blitzkvm.so $(BUILD)/pam_test
	./$(BUILD)/pam_test $(BUILD)/pam_blitzkvm.so

clean:
	rm -rf $(BUILD)
