#pragma once

#include <malloc.h>
#include <stddef.h>
#include <stdint.h>
#include <napi/native_api.h>

#define TAG "FlClash"

typedef const char *c_string;

typedef void (*mark_socket_func)(int id, int fd);

// cgo
extern void mark_socket(void *interface, int id, int fd);

// Only call_js creates napi_value objects. Producer threads queue plain C data.
napi_threadsafe_function bridge_create(napi_env env, napi_value callback);
int bridge_send_fd(napi_threadsafe_function fn, int64_t id, int64_t fd);
int bridge_send_log(napi_threadsafe_function fn, const char *text);
void bridge_release(napi_threadsafe_function fn);
