create exception e_custom_error 'custom error';

SET TERM ^ ;

CREATE OR ALTER PROCEDURE PARSE_PEOPLES_JSON (
    JSON_STR BLOB SUB_TYPE 1 SEGMENT SIZE 80)
RETURNS (
    ID   INTEGER,
    NAME VARCHAR(120))
AS
declare variable nullPtr TY$POINTER = x'0000000000000000';
declare variable json TY$POINTER;
declare variable jsonId TY$POINTER;
declare variable jsonName TY$POINTER;
begin
  json = js$func.parsetext(json_str);
  -- если JSON некорректный js$func.parsetext не сгененрирует исключение!
  -- и даже вернёт не NULL, а просто нулевой указаель
  -- поэтому надо обработать такой случай самостоятельно
  if (json is null or json = nullPtr) then
    exception e_custom_error 'invalid json';
  -- Опять же функции из этой библиотеки не проверяют корректность типов элементов
  -- и не возвращают ошибку понятную. Нам надо проверить тот ли тип мы обрабатываем.
  -- Иначе js$list.foreach вернёт "Access violation"
  if (js$base.SelfTypeName(json) != 'jsList') then
    exception e_custom_error 'Invalid JSON format. The top level of the JSON item must be a list. ';
  for
    select Obj
    from js$list.foreach(:json)
    as cursor c
  do
  begin
    -- Проверяем, что элемент массива - это объект, иначе
    -- js$obj.GetIntegerByName вернёт "Access violation"
    if (js$base.SelfTypeName(c.Obj) != 'jsObject') then
      exception e_custom_error 'Element of list is not object';
    -- js$obj.GetIntegerByName не проверяет существования элемента с заданным именем
    -- она просто молча вернёт 0!!!!! Надо самому проверить
    -- А js$obj.Field вернёт нулевой указатель
    if (js$obj.indexofname(c.Obj, 'id') < 0) then
      exception e_custom_error 'Field "id" not found in object';
    jsonId = js$obj.Field(c.Obj, 'id');
    if (js$base.selftypename(jsonId) = 'jsNull') then
      id = null;
    else if (js$base.selftypename(jsonId) = 'jsNumber') then
      id = js$obj.GetIntegerByName(c.Obj, 'id');
    else
      exception e_custom_error 'Field "id" is not number';

    if (js$obj.indexofname(c.Obj, 'name') < 0) then
      exception e_custom_error 'Field "name" not found in object';
    jsonName = js$obj.Field(c.Obj, 'name');
    if (js$str.selftypename(jsonName) = 'jsNull') then
      name = null;
    else
      name = js$str.value_(jsonName);
    suspend;
  end
  js$base.dispose(json);
  when any do
  begin
    js$base.dispose(json);
    exception;
  end
end
^

SET TERM ; ^

GRANT EXECUTE ON PACKAGE JS$FUNC TO PROCEDURE PARSE_PEOPLES_JSON;
GRANT USAGE ON EXCEPTION E_CUSTOM_ERROR TO PROCEDURE PARSE_PEOPLES_JSON;
GRANT EXECUTE ON PACKAGE JS$BASE TO PROCEDURE PARSE_PEOPLES_JSON;
GRANT EXECUTE ON PACKAGE JS$LIST TO PROCEDURE PARSE_PEOPLES_JSON;
GRANT EXECUTE ON PACKAGE JS$OBJ TO PROCEDURE PARSE_PEOPLES_JSON;
GRANT EXECUTE ON PACKAGE JS$STR TO PROCEDURE PARSE_PEOPLES_JSON;

SET TERM ^ ;

CREATE OR ALTER FUNCTION MAKE_JSON_DEPARTMENT_TREE
RETURNS BLOB SUB_TYPE 1 SEGMENT SIZE 80
AS
DECLARE VARIABLE JSON_TEXT BLOB SUB_TYPE TEXT;
  DECLARE VARIABLE JSON          TY$POINTER;
  DECLARE VARIABLE JSON_SUB_DEPS TY$POINTER;
BEGIN
  JSON = JS$OBJ.NEW_();
  FOR
      WITH RECURSIVE R
      AS (SELECT
              :JSON AS JSON,
              CAST(NULL AS TY$POINTER) AS PARENT_JSON,
              D.DEPT_NO,
              D.DEPARTMENT,
              D.HEAD_DEPT,
              D.MNGR_NO,
              D.BUDGET,
              D.LOCATION,
              D.PHONE_NO
          FROM DEPARTMENT D
          WHERE D.HEAD_DEPT IS NULL
          UNION ALL
          SELECT
              JS$OBJ.NEW_() AS JSON,
              R.JSON,
              D.DEPT_NO,
              D.DEPARTMENT,
              D.HEAD_DEPT,
              D.MNGR_NO,
              D.BUDGET,
              D.LOCATION,
              D.PHONE_NO
          FROM DEPARTMENT D
            JOIN R
                   ON D.HEAD_DEPT = R.DEPT_NO)
      SELECT
          JSON,
          PARENT_JSON,
          DEPT_NO,
          DEPARTMENT,
          HEAD_DEPT,
          MNGR_NO,
          BUDGET,
          LOCATION,
          PHONE_NO
      FROM R AS CURSOR C_DEP
  DO
  BEGIN
    -- для каждого нового подразделения заполняем значение полей JSON объекта
    JS$OBJ.ADDSTRING(C_DEP.JSON, 'dept_no', C_DEP.DEPT_NO);
    JS$OBJ.ADDSTRING(C_DEP.JSON, 'department', C_DEP.DEPARTMENT);
    IF (C_DEP.HEAD_DEPT IS NOT NULL) THEN
      JS$OBJ.ADDSTRING(C_DEP.JSON, 'head_dept', C_DEP.HEAD_DEPT);
    ELSE
      JS$OBJ.ADD_(C_DEP.JSON, 'head_dept', JS$NULL.GENERATE());
    IF (C_DEP.MNGR_NO IS NOT NULL) THEN
      JS$OBJ.ADDINTEGER(C_DEP.JSON, 'mngr_no', C_DEP.MNGR_NO);
    ELSE
      JS$OBJ.ADD_(C_DEP.JSON, 'mngr_no', JS$NULL.GENERATE());
    -- тут возможно ADDSTRING лучше, так как гарантированно сохранит точность
    JS$OBJ.ADDDOUBLE(C_DEP.JSON, 'budget', C_DEP.BUDGET);
    JS$OBJ.ADDSTRING(C_DEP.JSON, 'location', C_DEP.LOCATION);
    JS$OBJ.ADDSTRING(C_DEP.JSON, 'phone_no', C_DEP.PHONE_NO);
    -- в каждое подразделение добавляем список, в который будут
    -- вносится подчинённые подразделения
    JS$OBJ.ADD_(C_DEP.JSON, 'departments', JS$LIST.GENERATE());
    IF (C_DEP.PARENT_JSON IS NOT NULL) THEN
    BEGIN
      -- там где есть подразделения, есть и объект родительского объекта JSON
      -- получаем из этого родительского объекта поле со списком
      JSON_SUB_DEPS = JS$OBJ.FIELD(C_DEP.PARENT_JSON, 'departments');
      -- и добавляем в него текущее подразделение
      JS$LIST.ADD_(JSON_SUB_DEPS, C_DEP.JSON);
    END
  END
  -- генерируем JSON в виде текста
  JSON_TEXT = JS$FUNC.READABLETEXT(JSON);
  -- не забываем очистить указтель
  JS$OBJ.DISPOSE(JSON);
  RETURN JSON_TEXT;
  WHEN ANY DO
  BEGIN
    -- если была ошибка всё равно очищаем указатель
    JS$OBJ.DISPOSE(JSON);
    EXCEPTION;
  END
END
^

SET TERM ; ^


GRANT EXECUTE ON PACKAGE JS$OBJ TO FUNCTION MAKE_JSON_DEPARTMENT_TREE;
GRANT EXECUTE ON PACKAGE JS$NULL TO FUNCTION MAKE_JSON_DEPARTMENT_TREE;
GRANT EXECUTE ON PACKAGE JS$LIST TO FUNCTION MAKE_JSON_DEPARTMENT_TREE;
GRANT EXECUTE ON PACKAGE JS$FUNC TO FUNCTION MAKE_JSON_DEPARTMENT_TREE;
GRANT SELECT ON DEPARTMENT TO FUNCTION MAKE_JSON_DEPARTMENT_TREE;

SET TERM ^ ;

CREATE OR ALTER PACKAGE JSON_PARSE_DEPS
AS
BEGIN
  PROCEDURE PARSE_DEPARTMENT_TREE (
      JSON_TEXT BLOB SUB_TYPE TEXT)
  RETURNS (
      DEPT_NO    CHAR(3),
      DEPARTMENT VARCHAR(25),
      HEAD_DEPT  CHAR(3),
      MNGR_NO    SMALLINT,
      BUDGET     DECIMAL(18,2),
      LOCATION   VARCHAR(15),
      PHONE_NO   VARCHAR(20));
END^

RECREATE PACKAGE BODY JSON_PARSE_DEPS
AS
BEGIN
  PROCEDURE GET_DEPARTMENT_INFO (
      JSON TY$POINTER)
  RETURNS (
      DEPT_NO    CHAR(3),
      DEPARTMENT VARCHAR(25),
      HEAD_DEPT  CHAR(3),
      MNGR_NO    SMALLINT,
      BUDGET     DECIMAL(18,2),
      LOCATION   VARCHAR(15),
      PHONE_NO   VARCHAR(20),
      JSON_LIST  TY$POINTER);

  PROCEDURE PARSE_DEPARTMENT_TREE (
      JSON_TEXT BLOB SUB_TYPE TEXT)
  RETURNS (
      DEPT_NO    CHAR(3),
      DEPARTMENT VARCHAR(25),
      HEAD_DEPT  CHAR(3),
      MNGR_NO    SMALLINT,
      BUDGET     DECIMAL(18,2),
      LOCATION   VARCHAR(15),
      PHONE_NO   VARCHAR(20))
  AS
    DECLARE VARIABLE JSON    TY$POINTER;
    DECLARE VARIABLE NULLPTR TY$POINTER;
  BEGIN
    NULLPTR = X'0000000000000000';
    JSON = JS$FUNC.PARSETEXT(JSON_TEXT);
    -- если JSON некорректный js$func.parsetext не сгененрирует исключение!
    -- и даже вернёт не NULL, а просто нулевой указаель
    -- поэтому надо обработать такой случай самостоятельно
    IF (JSON IS NULL OR JSON = NULLPTR) THEN
      EXCEPTION E_CUSTOM_ERROR 'invalid json';
    FOR
      SELECT
          INFO.DEPT_NO,
          INFO.DEPARTMENT,
          INFO.HEAD_DEPT,
          INFO.MNGR_NO,
          INFO.BUDGET,
          INFO.LOCATION,
          INFO.PHONE_NO
      FROM JSON_PARSE_DEPS.GET_DEPARTMENT_INFO(:JSON) INFO
      INTO
          :DEPT_NO,
          :DEPARTMENT,
          :HEAD_DEPT,
          :MNGR_NO,
          :BUDGET,
          :LOCATION,
          :PHONE_NO
    DO
      SUSPEND;
    JS$OBJ.DISPOSE(JSON);
    WHEN ANY DO
    BEGIN
      JS$OBJ.DISPOSE(JSON);
      EXCEPTION;
    END
  END

  PROCEDURE GET_DEPARTMENT_INFO (
      JSON TY$POINTER)
  RETURNS (
      DEPT_NO    CHAR(3),
      DEPARTMENT VARCHAR(25),
      HEAD_DEPT  CHAR(3),
      MNGR_NO    SMALLINT,
      BUDGET     DECIMAL(18,2),
      LOCATION   VARCHAR(15),
      PHONE_NO   VARCHAR(20),
      JSON_LIST  TY$POINTER)
  AS
  BEGIN
    IF (JS$OBJ.INDEXOFNAME(JSON, 'dept_no') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "dept_no" not found';
    DEPT_NO = JS$OBJ.GETSTRINGBYNAME(JSON, 'dept_no');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'department') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "department" not found';
    DEPARTMENT = JS$OBJ.GETSTRINGBYNAME(JSON, 'department');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'head_dept') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "head_dept" not found';
    IF (JS$BASE.SELFTYPENAME(JS$OBJ.FIELD(JSON, 'head_dept')) = 'jsNull') THEN
      HEAD_DEPT = NULL;
    ELSE
      HEAD_DEPT = JS$OBJ.GETSTRINGBYNAME(JSON, 'head_dept');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'mngr_no') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "mngr_no" not found';
    IF (JS$BASE.SELFTYPENAME(JS$OBJ.FIELD(JSON, 'mngr_no')) = 'jsNull') THEN
      MNGR_NO = NULL;
    ELSE
      MNGR_NO = JS$OBJ.GETINTEGERBYNAME(JSON, 'mngr_no');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'budget') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "budget" not found';
    BUDGET = JS$OBJ.GETDOUBLEBYNAME(JSON, 'budget');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'location') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "location" not found';
    LOCATION = JS$OBJ.GETSTRINGBYNAME(JSON, 'location');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'phone_no') < 0) THEN
      EXCEPTION E_CUSTOM_ERROR 'field "phone_no" not found';
    PHONE_NO = JS$OBJ.GETSTRINGBYNAME(JSON, 'phone_no');
    IF (JS$OBJ.INDEXOFNAME(JSON, 'departments') >= 0) THEN
    BEGIN
      -- получаем список подчинённых подразделений
      JSON_LIST = JS$OBJ.FIELD(JSON, 'departments');
      IF (JS$BASE.SELFTYPENAME(JSON_LIST) != 'jsList') THEN
        EXCEPTION E_CUSTOM_ERROR 'Invalid JSON format. Field "departments" must be list';
      SUSPEND;
      -- обходим этот список и рекурсивно вызываем для него процедуру извлечения
      -- информации о каждом подраздении
      FOR
        SELECT
            INFO.DEPT_NO,
            INFO.DEPARTMENT,
            INFO.HEAD_DEPT,
            INFO.MNGR_NO,
            INFO.BUDGET,
            INFO.LOCATION,
            INFO.PHONE_NO,
            INFO.JSON_LIST
        FROM JS$LIST.FOREACH(:JSON_LIST) L
          LEFT JOIN JSON_PARSE_DEPS.GET_DEPARTMENT_INFO(L.OBJ) INFO
                 ON TRUE
        INTO
            :DEPT_NO,
            :DEPARTMENT,
            :HEAD_DEPT,
            :MNGR_NO,
            :BUDGET,
            :LOCATION,
            :PHONE_NO,
            :JSON_LIST
      DO
        SUSPEND;
    END
    ELSE
      EXCEPTION E_CUSTOM_ERROR 'Invalid JSON format. Field "departments" not found' || DEPT_NO;
  END
END
^

SET TERM ; ^


GRANT EXECUTE ON PACKAGE JS$FUNC TO PACKAGE JSON_PARSE_DEPS;
GRANT USAGE ON EXCEPTION E_CUSTOM_ERROR TO PACKAGE JSON_PARSE_DEPS;
GRANT EXECUTE ON PACKAGE JS$OBJ TO PACKAGE JSON_PARSE_DEPS;
GRANT EXECUTE ON PACKAGE JS$BASE TO PACKAGE JSON_PARSE_DEPS;
GRANT EXECUTE ON PACKAGE JS$LIST TO PACKAGE JSON_PARSE_DEPS;


