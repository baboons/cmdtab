// cmdtab-core C interface. Implemented in Rust (core/src/lib.rs).
#ifndef CMDTAB_CORE_H
#define CMDTAB_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CtEngine CtEngine;

/// A candidate. Strings are UTF-8 (pointer + length, no NUL needed) and are
/// copied by `ct_engine_set_items`.
typedef struct {
    uint64_t id;
    const uint8_t *app;
    size_t app_len;
    const uint8_t *title;
    size_t title_len;
    /// Stable key used for learning (e.g. the bundle identifier).
    const uint8_t *key;
    size_t key_len;
    /// Recency rank, 0 = most recently used.
    uint32_t mru;
} CtItem;

/// A highlighted range in UTF-16 code units (maps directly to NSRange).
typedef struct {
    uint32_t start;
    uint32_t len;
} CtRange;

typedef struct {
    uint64_t id;
    int32_t score;
    const CtRange *app_ranges;
    size_t app_ranges_len;
    const CtRange *title_ranges;
    size_t title_ranges_len;
} CtResult;

/// `learn_path` may be NULL for an in-memory engine.
CtEngine *ct_engine_new(const char *learn_path);
void ct_engine_free(CtEngine *engine);

void ct_engine_set_items(CtEngine *engine, const CtItem *items, size_t count);

/// Returns the number of results; read them with `ct_engine_result`. Results
/// (and their range pointers) stay valid until the next search/set_items.
size_t ct_engine_search(CtEngine *engine, const uint8_t *query, size_t query_len);
bool ct_engine_result(const CtEngine *engine, size_t index, CtResult *out);

void ct_engine_record(CtEngine *engine, const uint8_t *query, size_t query_len,
                      const uint8_t *key, size_t key_len);

/// Forgets all learned selections (in memory and on disk).
void ct_engine_clear_learning(CtEngine *engine);

const char *ct_version(void);

#ifdef __cplusplus
}
#endif

#endif
