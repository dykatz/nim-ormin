import std/[unittest, os, json, times, options, strutils]
import ormin
import ormin/query_hooks
importModel(DbBackend.mysql, "model_mysql", includeStatic = true)

doAssert getEnv("MYSQL_DATABASE") == "ormin_test", "Only the disposable ormin_test database is allowed"
let connection = getEnv("MYSQL_SOCKET", getEnv("MYSQL_HOST", "127.0.0.1") & ":" & getEnv("MYSQL_PORT", "3306"))
let db = open(connection, getEnv("MYSQL_USER"), getEnv("MYSQL_PASSWORD"), "ormin_test")

proc statementCount(db: DbConn): int64 =
  let s = prepareStmt(db, "SHOW SESSION STATUS LIKE 'Prepared_stmt_count'")
  defer: finalizeStmt(s)
  startQuery(db, s)
  doAssert stepQuery(db, s, true)
  bindResult(db, s, 1, result, int64, "count")

proc isolatedTransaction(db: DbConn) =
  transaction:
    query:
      insert ormin_mysql_parent(name = ?"other connection")

proc clean() =
  db.dropTable(sqlSchema)

createProc parents:
  select ormin_mysql_parent(id, name)
  orderby id

createIter parentNames:
  select ormin_mysql_parent(name)
  orderby id

type
  Parent = object
    id: int64
    name: string
  Nullable = object
    note: Option[string]
  BadResult = distinct string
  BadParam = distinct string

proc fromQueryHook(dest: var BadResult; value: string) =
  raise newException(ValueError, "intentional result conversion failure")
proc toQueryHook(dest: var string; value: BadParam) =
  raise newException(ValueError, "intentional parameter conversion failure")

clean()
try:
  db.createTable(sqlSchema)

  suite "MySQL/MariaDB":
    test "schema options, type parameters and case-sensitive identifiers":
      check db.getValue(sql"SELECT ENGINE FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='ormin_mysql_types'") == "InnoDB"
      check db.getValue(sql"SELECT NUMERIC_SCALE FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='ormin_mysql_types' AND column_name='amount'") == "10"
      query:
        insert ormin_mysql_Case(id = ?1, `select` = ?"reserved")
      let rows = query:
        select ormin_mysql_case(`select`)
      check rows == @["reserved"]
      check db.getValue(sql"SELECT @@session.time_zone") == "+00:00"

    test "CRUD and native generated ID":
      let id = query:
        insert ormin_mysql_parent(name = ?"first")
        returning id
      check id > 0
      query:
        update ormin_mysql_parent(name = ?"changed")
        where id == ?id
      let row = query:
        select ormin_mysql_parent(id, name)
        where id == ?id
        limit 1
      check row.name == "changed"
      query:
        delete ormin_mysql_parent
        where id == ?id
      check parents(db).len == 0
      let jsonId = query:
        insert ormin_mysql_parent(name = ?"json id")
        returning id
        produce json
      check jsonId["id"].getBiggestInt > 0
      query:
        delete ormin_mysql_parent

    test "parameters preserve Unicode, quotes, NULs and long strings/blobs":
      let text = "'\\; DROP TABLE nope; 💡\0" & repeat("z", 100000)
      let bytes = @[byte(0), 255, 42] & newSeq[byte](100000)
      query:
        insert ormin_mysql_types(note = ?text, payload = ?bytes)
      let row = query:
        select ormin_mysql_types(note, payload)
        limit 1
      check row.note == text
      check row.payload == bytes
      query:
        delete ormin_mysql_types

    test "empty and literal text/blob values are distinct from SQL NULL":
      let emptyBlob: seq[byte] = @[]
      query:
        insert ormin_mysql_types(note = ?"", payload = ?emptyBlob)
      let empty = query:
        select ormin_mysql_types(note, payload)
        limit 1
      check empty.note == ""
      check empty.payload.len == 0
      query:
        delete ormin_mysql_types
      query:
        insert ormin_mysql_types(note = "quote' backslash\\ NUL\0 💡")
      let literal = query:
        select ormin_mysql_types(note)
        limit 1
      check literal == "quote' backslash\\ NUL\0 💡"
      query:
        delete ormin_mysql_types

    test "numeric limits, exact decimals, booleans and temporal values":
      let signedValue = low(int64)
      let unsignedValue = high(uint64)
      let amount = "12345678901234567890.1234567890"
      let dt = parse("2026-11-11 12:34:56.123456", "yyyy-MM-dd HH:mm:ss'.'ffffff", utc())
      query:
        insert ormin_mysql_types(signed_value = ?signedValue, unsigned_value = ?unsignedValue,
          amount = ?amount, enabled = ?true, tiny = ?7, ratio = ?1.25,
          created = ?dt, stamp = ?dt, day = ?"2026-11-11", duration = ?"123:45:56.123456", state = ?"done")
      let row = query:
        select ormin_mysql_types(signed_value, unsigned_value, amount, enabled, tiny, ratio, created, stamp, day, duration, state)
        limit 1
      check row.signed_value == signedValue
      check row.unsigned_value == unsignedValue
      check row.amount == amount
      check row.enabled
      check row.tiny == 7
      check row.ratio == 1.25
      check row.created == dt
      check row.stamp == dt
      check row.day == "2026-11-11"
      check row.duration == "123:45:56.123456"
      check row.state == "done"
      expect ValueError:
        discard query:
          select ormin_mysql_types(unsigned_value)
          produce json
      query:
        delete ormin_mysql_types

    test "SQL NULL, JSON null, JSON parameters and typed options":
      let absent = none(string)
      let doc = %*{"value": [1, 2], "null": nil}
      query:
        insert ormin_mysql_types(note = ?absent, info = ?doc, enabled = %newJBool(true))
      let rows = query(Nullable):
        select ormin_mysql_types(note)
      check rows[0].note.isNone
      let jsonRows = query:
        select ormin_mysql_types(note, info, enabled)
        produce json
      check jsonRows[0]["note"].kind == JNull
      check jsonRows[0]["info"] == doc
      check jsonRows[0]["enabled"].getBool
      let jsonNull = newJNull()
      query:
        insert ormin_mysql_types(info = ?jsonNull)
      check db.getValue(sql"SELECT COUNT(*) FROM ormin_mysql_types WHERE info IS NOT NULL AND JSON_TYPE(info)='NULL'") == "1"
      query:
        delete ormin_mysql_types

    test "transactions and nested savepoints":
      transaction:
        query:
          insert ormin_mysql_parent(name = ?"committed")
        let ok = tryTransaction:
          query:
            insert ormin_mysql_parent(name = ?"committed")
        check not ok
        query:
          insert ormin_mysql_parent(name = ?"also committed")
      check parents(db).len == 2

    test "transaction depths are independent across connections":
      let other = open(connection, getEnv("MYSQL_USER"), getEnv("MYSQL_PASSWORD"), "ormin_test")
      try:
        expect ValueError:
          transaction:
            isolatedTransaction(other)
            raise newException(ValueError, "roll back only outer connection")
      finally:
        close(other)
      check db.getValue(sql"SELECT COUNT(*) FROM ormin_mysql_parent WHERE name='other connection'") == "1"
      db.exec(sql"DELETE FROM ormin_mysql_parent WHERE name='other connection'")
      expect ValueError:
        transaction:
          query:
            insert ormin_mysql_parent(name = ?"rolled back")
          raise newException(ValueError, "rollback")
      check parents(db).len == 2

    test "procedures, iterators, typed queries and offset-only pagination":
      check parents(db).len == 2
      let typed = query(Parent):
        select ormin_mysql_parent(id, name)
        orderby id
      check typed[0].name == "committed"
      let offsetRows = query:
        select ormin_mysql_parent(name)
        orderby id
        offset ?1
      check offsetRows == @["also committed"]
      for name in parentNames(db):
        check name == "committed"
        break
      check parents(db).len == 2

    test "automatic join, CTE, window and ilike":
      let id = parents(db)[0].id
      query:
        insert ormin_mysql_types(parent_id = ?id, note = ?"child")
      let joined = query:
        select ormin_mysql_types(note)
        join ormin_mysql_parent(name)
      check joined[0].name == "committed"
      let filtered = query:
        select ormin_mysql_parent(name)
        where ormin_mysql_parent.name `ilike` ?"COMMITTED"
      check filtered == @["committed"]
      let cteRows = query:
        with p(select ormin_mysql_parent(id, name))
        select p(name)
      check cteRows.len == 2
      let ranked = query:
        select ormin_mysql_parent(name, over(row_number(), orderby(id)) as rn)
      check ranked.len == 2
      let merged = query:
        select ormin_mysql_parent(name) where name == ?"committed"
        union
        select ormin_mysql_parent(name) where name == ?"also committed"
      check merged.len == 2

    test "statement affected-row counts":
      let s = prepareStmt(db, "UPDATE ormin_mysql_parent SET name=name WHERE name='committed'")
      defer: finalizeStmt(s)
      startQuery(db, s)
      check getAffectedRows(db, s) == 0 # changed rows, not matched rows

    test "a manually prepared statement can be rebound and executed again":
      let s = prepareStmt(db, "SELECT ?")
      defer: finalizeStmt(s)
      for i in 0 ..< 10:
        let text = $i
        bindParam(db, s, 1, text, string)
        startQuery(db, s)
        check stepQuery(db, s, true)
        var value: string
        bindResult(db, s, 0, value, string, "value")
        check value == text
        stopQuery(db, s)

    test "errors, hooks and repeated executions do not poison the connection":
      let before = statementCount(db)
      for i in 0 ..< 30:
        expect DbError:
          query:
            insert ormin_mysql_parent(name = ?"committed")
        expect ValueError:
          discard query(BadResult):
            select ormin_mysql_parent(name)
        let bad = BadParam("committed")
        expect ValueError:
          discard query:
            select ormin_mysql_parent(name)
            where name == ?bad
        check parents(db).len == 2
        for name in parentNames(db): break
      check statementCount(db) == before
      expect DbError:
        discard prepareStmt(db, "SELECT FROM invalid_syntax")
      check statementCount(db) == before
      let missing = tryQuery:
        select ormin_mysql_parent(name)
        where name == ?"missing"
        limit 1
      check missing == ""
      check statementCount(db) == before

finally:
  clean()
  close(db)
