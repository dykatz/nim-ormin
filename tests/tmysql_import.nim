## Exercise the external importer as well as compile-time capability diagnostics.
import std/[os, strutils]
import ormin
import ormin/db_utils
importModel(DbBackend.mysql, "model_mysql")

static:
  doAssert tableNames[2] == "ormin_mysql_Case"
  doAssert attributes[0].autoIncrement
  doAssert compiles(block:
    let db = default(DbConn)
    discard query:
      select ormin_mysql_parent(name))
  doAssert not compiles(block:
    let db = default(DbConn)
    query:
      insert ormin_mysql_parent(name = ?"x")
      onconflict(name)
      donothing())
  doAssert not compiles(block:
    let db = default(DbConn)
    discard query:
      insert ormin_mysql_parent(name = ?"x")
      returning name)
  doAssert not compiles(block:
    let db = default(DbConn)
    discard query:
      select ormin_mysql_parent(id)
      fulljoin ormin_mysql_types(note))

doAssert getEnv("MYSQL_DATABASE") == "ormin_test"
let connection = getEnv("MYSQL_SOCKET", getEnv("MYSQL_HOST", "127.0.0.1") & ":" & getEnv("MYSQL_PORT", "3306"))
let db = open(connection, getEnv("MYSQL_USER"), getEnv("MYSQL_PASSWORD"), "ormin_test")
const schema = staticLoad("model_mysql.sql")
db.createTable(schema, "ormin_mysql_parent")
try:
  let id = query:
    insert ormin_mysql_parent(name = ?"external importer")
    returning id
  let name = query:
    select ormin_mysql_parent(name)
    where id == ?id
    limit 1
  doAssert name == "external importer"
finally:
  db.dropTable(schema, "ormin_mysql_parent")
close(db)
