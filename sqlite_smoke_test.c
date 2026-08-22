#include <stdio.h>
#include <stdarg.h>

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

extern const char *sqlite3_libversion(void);
extern int sqlite3_open(const char *filename, sqlite3 **ppDb);
extern int sqlite3_close(sqlite3 *db);
extern int sqlite3_exec(sqlite3 *db, const char *sql,
    int (*callback)(void*, int, char**, char**),
    void *arg, char **errmsg);
extern int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
    sqlite3_stmt **ppStmt, const char **pzTail);
extern int sqlite3_step(sqlite3_stmt *pStmt);
extern int sqlite3_finalize(sqlite3_stmt *pStmt);
extern int sqlite3_bind_int(sqlite3_stmt *pStmt, int i, int iValue);
extern int sqlite3_bind_text(sqlite3_stmt *pStmt, int i, const char *zData,
    int nData, void(*xDel)(void*));
extern int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
extern const char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
extern const char *sqlite3_errmsg(sqlite3 *db);
extern void sqlite3_free(void *p);
extern int sqlite3_changes(sqlite3 *db);

#define SQLITE_OK 0
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_STATIC ((void(*)(void*))0)

int main() {
    sqlite3 *db = 0;
    char *errmsg = 0;
    int rc;

    fprintf(stderr, "SQLite version: %s\n", sqlite3_libversion());

    /* 1. Open in-memory database */
    rc = sqlite3_open(":memory:", &db);
    fprintf(stderr, "sqlite3_open: rc=%d db=%p\n", rc, (void*)db);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "FAIL: sqlite3_open failed: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    fprintf(stderr, "PASS: sqlite3_open\n");

    /* 2. Create a table */
    rc = sqlite3_exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)", 0, 0, &errmsg);
    fprintf(stderr, "sqlite3_exec(CREATE TABLE): rc=%d\n", rc);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "FAIL: CREATE TABLE: %s\n", errmsg ? errmsg : "(null)");
        return 1;
    }
    fprintf(stderr, "PASS: CREATE TABLE\n");

    /* 3. Insert via exec */
    rc = sqlite3_exec(db, "INSERT INTO t(id, name) VALUES(1, 'hello')", 0, 0, &errmsg);
    fprintf(stderr, "sqlite3_exec(INSERT): rc=%d\n", rc);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "FAIL: INSERT: %s\n", errmsg ? errmsg : "(null)");
        return 1;
    }
    fprintf(stderr, "PASS: INSERT\n");

    /* 4. Prepare a SELECT */
    sqlite3_stmt *stmt = 0;
    rc = sqlite3_prepare_v2(db, "SELECT id, name FROM t", -1, &stmt, 0);
    fprintf(stderr, "sqlite3_prepare_v2: rc=%d stmt=%p\n", rc, (void*)stmt);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "FAIL: prepare: %s\n", sqlite3_errmsg(db));
        return 1;
    }

    /* 5. Step through results */
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int id = sqlite3_column_int(stmt, 0);
        const char *name = sqlite3_column_text(stmt, 1);
        fprintf(stderr, "ROW: id=%d name=%s\n", id, name ? name : "(null)");
    }
    fprintf(stderr, "sqlite3_step final rc=%d (DONE=101)\n", rc);
    if (rc != SQLITE_DONE) {
        fprintf(stderr, "FAIL: step: %s\n", sqlite3_errmsg(db));
        return 1;
    }

    /* 6. Finalize */
    rc = sqlite3_finalize(stmt);
    fprintf(stderr, "sqlite3_finalize: rc=%d\n", rc);

    /* 7. Close */
    rc = sqlite3_close(db);
    fprintf(stderr, "sqlite3_close: rc=%d\n", rc);

    fprintf(stderr, "ALL TESTS PASSED\n");
    return 0;
}
