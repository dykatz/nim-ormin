## Shared MySQL/MariaDB driver backed by db_connector's native prepared API.
import std/[json, times, strutils, os]
import db_connector/db_common
from db_connector/db_mysql import nil
import query_hooks
export db_common

type
  DbConn* = db_mysql.DbConn
  PStmt* = ref object
    statement: db_mysql.SqlPrepared
    row: seq[db_mysql.DbValue]
  varcharType* = string
  fixedcharType* = string
  enumType* = string
  decimalType* = string ## Exact decimal text, never rounded through float.
  blobType* = seq[byte]
  intType* = int64
  uintType* = uint64
  serialType* = uint64
  floatType* = float64
  boolType* = bool
  timestampType* = DateTime
  datetimeType* = DateTime
  dateType* = string
  timeType* = string ## MySQL TIME can represent durations beyond 24 hours.
  jsonType* = JsonNode

var jsonTimeFormat* = "yyyy-MM-dd HH:mm:ss"

proc dbError*(db: DbConn) {.noreturn.} =
  db_mysql.dbError(db)

proc execMysqlTransaction*(db: DbConn; statement: string) =
  ## Internal transaction-control path. Unlike queries, these commands must
  ## use the text protocol on MySQL. Never interpolate application values.
  when defined(debugOrminTrace): echo "[[Ormin Executing]]: ", statement
  db_mysql.exec(db, SqlQuery(statement))

proc close*(db: DbConn) =
  db_mysql.close(db)

proc open*(connection, user, password, database: string): DbConn =
  ## connection: host[:port], or an absolute Unix socket path.
  if connection.isAbsolute:
    result = db_mysql.open("localhost", user, password, database, socket = connection)
  else:
    result = db_mysql.open(connection, user, password, database)
  try:
    if not db_mysql.setEncoding(result, "utf8mb4"): dbError(result)
    db_mysql.exec(result, sql"SET time_zone = '+00:00'")
  except:
    close(result)
    raise

proc finalizeStmt*(s: PStmt) =
  if s != nil:
    try: db_mysql.finalize(s.statement)
    finally: s.row.setLen(0)

proc prepareStmt*(db: DbConn; q: string): PStmt =
  when defined(debugOrminTrace): echo "[[Ormin Executing]]: ", q
  let statement = db_mysql.prepare(db, q)
  result = PStmt(statement: statement)

template startBindings*(s: PStmt; n: int) = discard

template bindNullParam*(db: DbConn; s: PStmt; idx: int) =
  db_mysql.bindNull(s.statement, idx)

proc bindParam*[T](db: DbConn; s: PStmt; idx: int; x: T; t: typedesc) =
  when T is seq[byte] or T is SomeInteger or T is SomeFloat:
    db_mysql.bindParam(s.statement, idx, x)
  elif T is bool:
    db_mysql.bindParam(s.statement, idx, int(x))
  else:
    let text = when T is DateTime: x.utc.format("yyyy-MM-dd HH:mm:ss'.'ffffff")
                else: $x
    db_mysql.bindParam(s.statement, idx, text)

proc bindParamJson*(db: DbConn; s: PStmt; idx: int; x: JsonNode; t: typedesc) =
  if x.kind == JNull:
    bindNullParam(db, s, idx)
  else:
    when t is JsonNode:
      bindParam(db, s, idx, x, t)
    elif t is string or t is DateTime:
      if x.kind != JString: raise newException(ValueError, "expected JSON string")
      bindParam(db, s, idx, x.str, string)
    elif t is bool:
      if x.kind != JBool: raise newException(ValueError, "expected JSON bool")
      bindParam(db, s, idx, x.bval, bool)
    elif t is SomeInteger:
      if x.kind != JInt: raise newException(ValueError, "expected JSON integer")
      when t is SomeUnsignedInt:
        if x.num < 0: raise newException(ValueError, "negative unsigned integer")
      bindParam(db, s, idx, x.num, int64)
    elif t is SomeFloat:
      if x.kind notin {JInt, JFloat}: raise newException(ValueError, "expected JSON number")
      bindParam(db, s, idx, x.getFloat, float64)
    else:
      {.error: "unsupported MySQL JSON parameter type".}

proc columnIsNull*(db: DbConn; s: PStmt; idx: int): bool =
  s.row[idx].kind == db_mysql.dvNull

proc columnText(s: PStmt; idx: int): string =
  s.row[idx].data

proc bindResult*[T](db: DbConn; s: PStmt; idx: int; dest: var T; t: typedesc; name: string) =
  when T is DbValue:
    dest.isNull = columnIsNull(db, s, idx)
    if not dest.isNull: bindResult(db, s, idx, dest.value, t, name)
  else:
    if columnIsNull(db, s, idx):
      when T is JsonNode: dest = newJNull()
      else: dest = default(T)
    else:
      let text = columnText(s, idx)
      when T is string: dest = text
      elif T is SomeUnsignedInt: dest = T(parseBiggestUInt(text))
      elif T is SomeSignedInt: dest = T(parseBiggestInt(text))
      elif T is SomeFloat: dest = T(parseFloat(text))
      elif T is bool: dest = parseBiggestInt(text) != 0
      elif T is JsonNode: dest = parseJson(text)
      elif T is seq[byte]:
        dest = newSeq[byte](text.len)
        if text.len > 0: copyMem(addr dest[0], unsafeAddr text[0], text.len)
      elif T is DateTime:
        let dot = text.find('.')
        dest = if dot < 0: parse(text, "yyyy-MM-dd HH:mm:ss", utc())
               else: parse(text & repeat('0', 6 - (text.len-dot-1)), "yyyy-MM-dd HH:mm:ss'.'ffffff", utc())
      else: {.error: "unsupported MySQL result type".}

template createJObject*(): untyped = newJObject()
template createJArray*(): untyped = newJArray()

proc bindResultJson*(db: DbConn; s: PStmt; idx: int; obj: JsonNode; t: typedesc; name: string) =
  if columnIsNull(db, s, idx):
    obj[name] = newJNull()
  else:
    var value: t
    bindResult(db, s, idx, value, t, name)
    when t is DateTime: obj[name] = %value.format(jsonTimeFormat)
    elif t is uint64:
      if value > uint64(high(int64)):
        raise newException(ValueError, "unsigned value exceeds JSON integer range; use Nim results")
      obj[name] = %int64(value)
    else: obj[name] = %value

proc startQuery*(db: DbConn; s: PStmt) =
  s.row.setLen(0)
  db_mysql.exec(s.statement)

template stopQuery*(db: DbConn; s: PStmt) = discard # finalizeStmt owns all resources

proc stepQuery*(db: DbConn; s: PStmt; returnsData: bool): bool =
  if not returnsData: return true # startQuery has already executed the command
  db_mysql.fetch(s.statement, s.row)

proc getLastId*(db: DbConn; s: PStmt): uint64 = db_mysql.insertId(s.statement)
proc getAffectedRows*(db: DbConn; s: PStmt): uint64 = db_mysql.affectedRows(s.statement)

proc bindInsertId*[T](db: DbConn; s: PStmt; dest: var T; name: string) =
  let id = getLastId(db, s)
  when T is JsonNode:
    if id > uint64(high(int64)): raise newException(ValueError, "insert ID exceeds JSON integer range")
    dest[name] = %int64(id)
  else:
    dest = T(id)

proc execMysql*(db: DbConn; statement: string) =
  ## Schema utilities and transaction commands use the text protocol.
  db_mysql.exec(db, SqlQuery(statement))

proc exec*(db: DbConn; statement: SqlQuery) = execMysql(db, string(statement))

proc getValue*(db: DbConn; statement: SqlQuery): string =
  db_mysql.getValue(db, statement)
