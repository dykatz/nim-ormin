/* Use the installed client's MYSQL_BIND layout, not db_connector's legacy ABI.
 * All buffers belong to the statement and are released even after exceptions. */
#ifndef ORMIN_MYSQL_NATIVE_H
#define ORMIN_MYSQL_NATIVE_H
#include <mysql.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  MYSQL_STMT *stmt;
  MYSQL_BIND *params, *columns;
  unsigned long param_count, column_count;
} ormin_mysql_statement;

static void *ormin_mysql_open(const char *host, const char *user,
    const char *password, const char *database, unsigned int port,
    const char *socket) {
  MYSQL *db = mysql_init(NULL);
  if (!db) return NULL;
  /* On failure return the handle so Nim can copy its error before closing it. */
  mysql_real_connect(db, host, user, password, database, port, socket, 0);
  return db;
}
static const char *ormin_mysql_error(void *db) { return mysql_error((MYSQL *)db); }
static void ormin_mysql_close(void *db) { mysql_close((MYSQL *)db); }
static int ormin_mysql_charset(void *db) {
  if (mysql_set_character_set((MYSQL *)db, "utf8mb4")) return 1;
  return mysql_query((MYSQL *)db, "SET time_zone = '+00:00'");
}
/* MySQL does not prepare every transaction-control command (notably
 * savepoint operations). These contain only library-generated SQL, no values. */
static int ormin_mysql_transaction(void *db, const char *sql, unsigned long len) {
  return mysql_real_query((MYSQL *)db, sql, len);
}
static void *ormin_mysql_prepare(void *db, const char *sql, unsigned long len) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->stmt = mysql_stmt_init((MYSQL *)db);
  if (!s->stmt) { free(s); return NULL; }
  /* Retain failed statements until Nim has copied mysql_stmt_error. */
  mysql_stmt_prepare(s->stmt, sql, len);
  s->param_count = mysql_stmt_param_count(s->stmt);
  if (s->param_count) s->params = (MYSQL_BIND *)calloc(s->param_count, sizeof(MYSQL_BIND));
  return s;
}
static const char *ormin_mysql_stmt_error(void *handle) {
  return mysql_stmt_error(((ormin_mysql_statement *)handle)->stmt);
}
static void ormin_mysql_clear_columns(ormin_mysql_statement *s) {
  mysql_stmt_free_result(s->stmt);
  if (s->columns) {
    for (unsigned long i = 0; i < s->column_count; ++i) {
      free(s->columns[i].buffer);
      free(s->columns[i].length);
      free(s->columns[i].is_null);
    }
    free(s->columns);
  }
  s->columns = NULL;
  s->column_count = 0;
}
static void ormin_mysql_finalize(void *handle) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)handle;
  if (!s) return;
  ormin_mysql_clear_columns(s);
  mysql_stmt_close(s->stmt);
  if (s->params) {
    for (unsigned long i = 0; i < s->param_count; ++i) free(s->params[i].buffer);
    free(s->params);
  }
  free(s);
}
static int ormin_mysql_bind(void *handle, unsigned int index,
    const void *data, unsigned long length, int is_null, int binary) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)handle;
  if (index >= s->param_count || !s->params) return 1;
  MYSQL_BIND *b = &s->params[index];
  free(b->buffer);
  memset(b, 0, sizeof(*b));
  b->buffer_type = is_null ? MYSQL_TYPE_NULL : (binary ? MYSQL_TYPE_BLOB : MYSQL_TYPE_STRING);
  if (!is_null) {
    b->buffer = malloc(length ? length : 1);
    if (!b->buffer) return 1;
    if (length) memcpy(b->buffer, data, length);
    b->buffer_length = length;
  }
  return 0;
}
static int ormin_mysql_execute(void *handle) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)handle;
  ormin_mysql_clear_columns(s);
  if (s->param_count && (!s->params || mysql_stmt_bind_param(s->stmt, s->params))) return 1;
  if (mysql_stmt_execute(s->stmt)) return 1;
  s->column_count = mysql_stmt_field_count(s->stmt);
  if (!s->column_count) return 0;
  s->columns = (MYSQL_BIND *)calloc(s->column_count, sizeof(MYSQL_BIND));
  if (!s->columns) return 1;
  for (unsigned long i = 0; i < s->column_count; ++i) {
    MYSQL_BIND *b = &s->columns[i];
    b->buffer_type = MYSQL_TYPE_STRING;
    b->buffer_length = 256;
    b->buffer = malloc(b->buffer_length);
    b->length = (unsigned long *)calloc(1, sizeof(*b->length));
    b->is_null = calloc(1, sizeof(*b->is_null));
    if (!b->buffer || !b->length || !b->is_null) return 1;
  }
  return mysql_stmt_bind_result(s->stmt, s->columns) || mysql_stmt_store_result(s->stmt);
}
/* 1 = row, 0 = end, -1 = error. Truncated fields are fetched at full length. */
static int ormin_mysql_step(void *handle) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)handle;
  int status = mysql_stmt_fetch(s->stmt);
  if (status == MYSQL_NO_DATA) return 0;
  if (status == 0 || status == MYSQL_DATA_TRUNCATED) return 1;
  return -1;
}
static int ormin_mysql_is_null(void *handle, unsigned int index) {
  return *(((ormin_mysql_statement *)handle)->columns[index].is_null) != 0;
}
static unsigned long ormin_mysql_length(void *handle, unsigned int index) {
  return *(((ormin_mysql_statement *)handle)->columns[index].length);
}
static int ormin_mysql_column(void *handle, unsigned int index, void *data, unsigned long len) {
  ormin_mysql_statement *s = (ormin_mysql_statement *)handle;
  MYSQL_BIND b;
  memset(&b, 0, sizeof(b));
  b.buffer_type = MYSQL_TYPE_STRING;
  b.buffer = data;
  b.buffer_length = len;
  return mysql_stmt_fetch_column(s->stmt, &b, index, 0);
}
static unsigned long long ormin_mysql_insert_id(void *handle) {
  return mysql_stmt_insert_id(((ormin_mysql_statement *)handle)->stmt);
}
static unsigned long long ormin_mysql_affected(void *handle) {
  return mysql_stmt_affected_rows(((ormin_mysql_statement *)handle)->stmt);
}
#endif
