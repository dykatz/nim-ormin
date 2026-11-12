## Shared MySQL/MariaDB driver. Requires mysql_config (or mariadb_config).
import std/[json, times, strutils, os]
import db_connector/db_common
from db_connector/db_mysql import nil
import query_hooks
export db_common

const mysqlConfig* {.strdefine.} = "mysql_config"
const clientFlags = static:
  let flags = gorgeEx(quoteShell(mysqlConfig) & " --cflags")
  doAssert flags.exitCode == 0, "Install MySQL/MariaDB client headers and mysql_config, or use -d:mysqlConfig=/path/to/mariadb_config"
  flags.output
const clientLibs = static:
  let flags = gorgeEx(quoteShell(mysqlConfig) & " --libs")
  doAssert flags.exitCode == 0, "Cannot obtain MySQL/MariaDB client linker flags"
  flags.output
{.passC: clientFlags.}
{.passL: clientLibs.}
const nativeHeader = currentSourcePath().parentDir / "mysql_native.h"

type
  DbConn* = db_mysql.DbConn
  PStmt* = pointer
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

{.push header: nativeHeader, importc, nodecl.}
proc ormin_mysql_open(host, user, password, database: cstring; port: cuint; socket: cstring): DbConn
proc ormin_mysql_error(db: DbConn): cstring
proc ormin_mysql_close(db: DbConn)
proc ormin_mysql_charset(db: DbConn): cint
proc ormin_mysql_prepare(db: DbConn; sql: cstring; length: culong): PStmt
proc ormin_mysql_stmt_error(s: PStmt): cstring
proc ormin_mysql_finalize(s: PStmt)
proc ormin_mysql_bind(s: PStmt; index: cuint; data: pointer; length: culong; isNull, binary: cint): cint
proc ormin_mysql_execute(s: PStmt): cint
proc ormin_mysql_step(s: PStmt): cint
proc ormin_mysql_is_null(s: PStmt; index: cuint): cint
proc ormin_mysql_length(s: PStmt; index: cuint): culong
proc ormin_mysql_column(s: PStmt; index: cuint; data: pointer; length: culong): cint
proc ormin_mysql_insert_id(s: PStmt): uint64
proc ormin_mysql_affected(s: PStmt): uint64
{.pop.}

proc dbError*(db: DbConn) {.noreturn.} =
  let detail = if cast[pointer](db) == nil: "cannot allocate MySQL connection" else: $ormin_mysql_error(db)
  raise newException(DbError, if detail.len == 0: "MySQL query returned no row" else: detail)

proc stmtError(s: PStmt) {.noreturn.} =
  let detail = $ormin_mysql_stmt_error(s)
  raise newException(DbError, if detail.len == 0: "MySQL statement or buffer allocation failed" else: detail)

proc close*(db: DbConn) =
  if cast[pointer](db) != nil: ormin_mysql_close(db)

proc open*(connection, user, password, database: string): DbConn =
  ## connection: host[:port], or an absolute Unix socket path.
  var host = connection
  var socket: cstring = nil
  var port: cuint = 0
  if connection.isAbsolute:
    host = "localhost"
    socket = connection.cstring
  elif ':' in connection:
    let colon = connection.rfind(':')
    port = cuint(parseUInt(connection[colon+1 .. ^1]))
    if port == 0 or port > 65535: raise newException(ValueError, "invalid MySQL port")
    host = connection[0 ..< colon]
  result = ormin_mysql_open(host.cstring, user.cstring, password.cstring,
                           database.cstring, port, socket)
  if cast[pointer](result) == nil: dbError(result)
  if ($ormin_mysql_error(result)).len > 0 or ormin_mysql_charset(result) != 0:
    let failed = result
    try: dbError(failed)
    finally: close(failed)

proc finalizeStmt*(s: PStmt) {.raises: [].} = ormin_mysql_finalize(s)

proc prepareStmt*(db: DbConn; q: string): PStmt =
  when defined(debugOrminTrace): echo "[[Ormin Executing]]: ", q
  result = ormin_mysql_prepare(db, q.cstring, q.len.culong)
  if result == nil: dbError(db)
  if ($ormin_mysql_stmt_error(result)).len > 0:
    let failed = result
    try: stmtError(failed)
    finally: finalizeStmt(failed)

template startBindings*(s: PStmt; n: int) = discard

proc bindBytes(s: PStmt; idx: int; data: pointer; length: int; binary = false) =
  if ormin_mysql_bind(s, cuint(idx-1), data, culong(length), 0, cint(binary)) != 0:
    stmtError(s)

template bindNullParam*(db: DbConn; s: PStmt; idx: int) =
  if ormin_mysql_bind(s, cuint(idx-1), nil, 0, 1, 0) != 0: stmtError(s)

proc bindParam*[T](db: DbConn; s: PStmt; idx: int; x: T; t: typedesc) =
  when T is seq[byte]:
    bindBytes(s, idx, (if x.len == 0: nil else: unsafeAddr x[0]), x.len, true)
  else:
    let text = when T is DateTime: x.utc.format("yyyy-MM-dd HH:mm:ss'.'ffffff")
               elif T is bool: (if x: "1" else: "0")
               else: $x
    bindBytes(s, idx, cast[pointer](text.cstring), text.len)

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
  ormin_mysql_is_null(s, idx.cuint) != 0

proc columnText(s: PStmt; idx: int): string =
  result = newString(int(ormin_mysql_length(s, idx.cuint)))
  if result.len > 0 and ormin_mysql_column(s, idx.cuint, addr result[0], result.len.culong) != 0:
    stmtError(s)

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
  if ormin_mysql_execute(s) != 0: stmtError(s)

template stopQuery*(db: DbConn; s: PStmt) = discard # finalizeStmt owns all resources

proc stepQuery*(db: DbConn; s: PStmt; returnsData: bool): bool =
  if not returnsData: return true # startQuery has already executed the command
  let status = ormin_mysql_step(s)
  if status < 0: stmtError(s)
  result = status == 1

proc getLastId*(db: DbConn; s: PStmt): uint64 = ormin_mysql_insert_id(s)
proc getAffectedRows*(db: DbConn; s: PStmt): uint64 = ormin_mysql_affected(s)

proc bindInsertId*[T](db: DbConn; s: PStmt; dest: var T; name: string) =
  let id = getLastId(db, s)
  when T is JsonNode:
    if id > uint64(high(int64)): raise newException(ValueError, "insert ID exceeds JSON integer range")
    dest[name] = %int64(id)
  else:
    dest = T(id)

proc execMysql*(db: DbConn; statement: string) =
  ## Used by schema utilities, without db_connector's legacy dynamic loader.
  let s = prepareStmt(db, statement)
  defer: finalizeStmt(s)
  startQuery(db, s)

proc exec*(db: DbConn; statement: SqlQuery) = execMysql(db, string(statement))

proc getValue*(db: DbConn; statement: SqlQuery): string =
  let s = prepareStmt(db, string(statement))
  defer: finalizeStmt(s)
  startQuery(db, s)
  if stepQuery(db, s, true): bindResult(db, s, 0, result, string, "")
