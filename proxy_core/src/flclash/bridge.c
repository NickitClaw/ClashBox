#include "bridge.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    int64_t id;
    int64_t fd;
    char *text;
} bridge_payload;

static void bridge_call_js(napi_env env, napi_value callback, void *context, void *raw) {
    bridge_payload *payload = raw;
    if (!payload) return;
    if (env && callback) {
        napi_value args[2], receiver;
        napi_get_undefined(env, &receiver);
        if (payload->text) {
            napi_create_string_utf8(env, "startLog", NAPI_AUTO_LENGTH, &args[0]);
            napi_create_string_utf8(env, payload->text, NAPI_AUTO_LENGTH, &args[1]);
        } else {
            napi_create_int64(env, payload->id, &args[0]);
            napi_create_int64(env, payload->fd, &args[1]);
        }
        napi_call_function(env, receiver, callback, 2, args, NULL);
    }
    free(payload->text);
    free(payload);
}

napi_threadsafe_function bridge_create(napi_env env, napi_value callback) {
    napi_value name;
    napi_threadsafe_function fn = NULL;
    if (napi_create_string_utf8(env, "ClashBox callback", NAPI_AUTO_LENGTH, &name) != napi_ok) return NULL;
    if (napi_create_threadsafe_function(env, callback, NULL, name, 1024, 1,
        NULL, NULL, NULL, bridge_call_js, &fn) != napi_ok) return NULL;
    return fn;
}

static int bridge_send(napi_threadsafe_function fn, bridge_payload *payload) {
    if (!payload) return 0;
    if (napi_call_threadsafe_function(fn, payload, napi_tsfn_nonblocking) == napi_ok) return 1;
    free(payload->text);
    free(payload);
    return 0;
}

int bridge_send_fd(napi_threadsafe_function fn, int64_t id, int64_t fd) {
    bridge_payload *payload = calloc(1, sizeof(*payload));
    if (!payload) return 0;
    payload->id = id;
    payload->fd = fd;
    return bridge_send(fn, payload);
}

int bridge_send_log(napi_threadsafe_function fn, const char *text) {
    bridge_payload *payload = calloc(1, sizeof(*payload));
    if (!payload) return 0;
    payload->text = strdup(text);
    if (!payload->text) { free(payload); return 0; }
    return bridge_send(fn, payload);
}

void bridge_release(napi_threadsafe_function fn) {
    napi_release_threadsafe_function(fn, napi_tsfn_abort);
}


void mark_socket(void *interface, int id, int fd) {
    mark_socket_func func = (mark_socket_func)(interface);
    func(id, fd);
}
