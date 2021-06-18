# UDR для сборки и разбора JSON на Firebird

Как известно СУБД Firebird не имеет встроенной поддержки JSON. Однако если что-то сильно нужно, то всегда можно найти решение. Обычно предлагается собирать и собирать JSON на стороне клиентского приложения. Здесь я расскажу как это можно сделать на стороне сервера.

## Сборка и разбор JSON с помощью PSQL

Попытка решить это исключительно в рамках PSQL может вызвать много проблем.

При сборке больших JSON на стороне сервера их приходится помещать в BLOB.
Как известно конкатенация строк с BLOB приводит к созданию множества временных BLOB. Когда размер таких BLOB не превышает одну страницу, то они будут находиться в оперативной памяти, в противном случае страницы BLOB приходится сбрасывать в файл БД, что приводит к "распуханию" вашей БД.
Для того чтобы уменьшить негативное влияние конкатенации BLOB можно накапливать результаты сборки в промежуточный буфер `VARCHAR(8191) CHARACTER SET UTF8`.
А затем присоединять такой буфер к переменной типа BLOB. Причём для конкатенации строк к BLOB желательно использовать агрегатную функцию LIST, если это возможно.

Существует также специальная сборка Firebird со встроенной функцией BLOB_APPEND, которая решает проблему конкатенации BLOB, но пока она не доступна для широкого использования.

В Firebird 5.0 ввели специальный системный пакет RDB$BLOB_UTILS, который так же позволяет бороться с проблемой конкатенации BLOB. В настоящий момент Firebird 5.0  на начальной стадии разработки, и пока не может быть использован в промышленных системах.

Вторая проблема которую вам необходимо решить - экранирование значений перед тем как использовать их внутри JSON. В принципе это можно успешно решить в рамках PSQL, однако учтите,  что скорее всего подобные функции для символьных типов данных будут содержать множество вызов REPLACE, что негативно повлияет на производительность.

```sql
 -- экранирование строк
  function Escape_String(AString varchar(8191) character set utf8)
  returns varchar(8191) character set utf8
  as
  begin
    AString = REPLACE(AString, '\', '\\');
    AString = REPLACE(AString, ASCII_CHAR(0x08), '\b');
    AString = REPLACE(AString, ASCII_CHAR(0x09), '\t');
    AString = REPLACE(AString, ASCII_CHAR(0x0A), '\r');
    AString = REPLACE(AString, ASCII_CHAR(0x0C), '\f');
    AString = REPLACE(AString, ASCII_CHAR(0x0D), '\n');
    AString = REPLACE(AString, '"', '\"');
    AString = REPLACE(AString, '/', '\/');
    RETURN AString;
  end
```

Разбор JSON на стороне PSQL ещё более сложная задача, и хотя она вполне решаема, производительность таких решений будет желать лучшего.

## Сборка и разбор JSON с помощью UDR

Можно попробовать пойти другим путём и написать UDR на внешнем языке программирования. И тут тоже есть два варианта:

* Делать сборку/разбор JSON для одного заранее известного формата
* Написать универсальную библиотеку для сборки/разбора JSON любого формата

Первый вариант будет наиболее производителен, но при изменении формата или необходимости разобрать другой JSON вам скорее всего придётся переписывать вашу UDR.

Второй вариант написать намного сложнее. Далее я расскажу об одной из таких UDR библиотек под названием [udr-lkJSON](https://github.com/mnf71/udr-lkJSON).
Библиотека с полностью открытыми исходными кодами под лицензией MIT и свободна для использования. Она написана на языке Free Pascal. Её автор Максим Филатов, ранее являлся сотрудником Ансофт, сегодня работает в Московской Бирже.

## Установка UDR lkJSON

Установить UDR lkJSON можно начиная с Firebird 3.0 и выше (Firebird 2.5 не поддерживал UDR).
Вы можете собрать библиотеку скачав исходные код по ссылке выше, либо скачать готовую библиотеку под нужную вам платформу по адресу [https://github.com/mnf71/udr-lkJSON/tree/main/lib](https://github.com/mnf71/udr-lkJSON/tree/main/lib).

После скачивания или сборки готовую библиотеку необходимо разместить в каталог
- в Windows -- `Firebird30\plugins\udr`, где Firebird30 - корневой каталог установки Firebird
- в Linix -- `/firebird/plugins/udr`

Далее библиотеку необходимо зарегистрировать в вашей базе данных. Для этого необходимо выполнить следующий скрипт [udrJSON.sql](https://github.com/mnf71/udr-lkJSON/blob/main/udrJSON.sql).


```
isql "inet4://localhost/test" -user SYSDBA -password masterkey -i udrJSON.sql
```

После установки UDR её предлагается проверить с помощью скрипта [verify.sql](https://github.com/mnf71/udr-lkJSON/blob/main/verify.sql)

В скрипте происходит вызов функции для разбора JSON и его сборка обратно в строку. Если исходный JSON будет такой же, как вновь собранный, то всё в порядке. В реальности полностью совпадать строки не будут, так как сборка JSON происходит без учёта красивого форматирования. Но содержимое должно быть идентичным.

Проверка происходит для двух наборов (процедура + функция)
- `js$func.ParseText` -- разбор JSON заданного в виде BLOB. `js$func.GenerateText` -- сборка JSON с возвратом BLOB.
- `js$func.ParseString` -- разбор JSON заданного в виде VARCHAR(N). `js$func.GenerateString` -- сборка JSON с возвратом VARCHAR(N).

## Как это работает

Библиотека udr-lkJSON основана на свободной библиотеки lkJSON для генерирования и разбора JSON. Поэтому чтобы хорошо представлять себе как работать с UDR-lkJSON желательно ознакомится с библиотекой [lkjson](https://sourceforge.net/projects/lkjson/).

При разборе JSON часть элементов могут быть простыми типами, которые существуют в Firebird (INTEGER, DOUBLE PRECISION, VARCHAR(N), BOOLEAN), а часть сложными -- объекты и массивы.
Сложные объекты возвращаются как указатель на внутренний объект из библиотеки lkJSON. Указатель отображается в домен `TY$POINTER`. Этот домен определён следующим образом:

```sql
CREATE DOMAIN TY$POINTER AS
CHAR(8) CHARACTER SET OCTETS;
```
 
Кроме того, если в JSON встречается NULL, то он не будет возвращён в простые типы! Вам придётся распознавать это значение отдельно. Это связано с тем, что библиотека UDR-lkJSON просто копирует методы
классов библиотеки lkJSON в PSQL пакеты. А как известно простые типы в Pascal не имеют отдельного состояния для NULL.

## Описание PSQL пакетов из UDR-lkJSON

### Пакет JS$BASE

Заголовок этого пакета выглядит следующим образом:

```sql
CREATE OR ALTER PACKAGE JS$BASE
AS
BEGIN
  /* TlkJSONbase = class
     TlkJSONtypes =
       (jsBase, jsNumber, jsString, jsBoolean, jsNull, jsList, jsObject);
        0       1         2         3          4       5       6
  */
  FUNCTION Dispose(Self TY$POINTER) RETURNS SMALLINT; /* 0 - succes */

  FUNCTION Field(Self TY$POINTER, Name VARCHAR(128) /* 1..N = Idx */) RETURNS TY$POINTER;

  FUNCTION Count_(Self TY$POINTER) RETURNS INTEGER;
  FUNCTION Child(Self TY$POINTER, Idx INTEGER, Obj TY$POINTER = NULL /* Get */) RETURNS TY$POINTER;

  FUNCTION Value_(Self TY$POINTER, Val VARCHAR(32765) = NULL /* Get */) RETURNS VARCHAR(32765);
  FUNCTION WideValue_(Self TY$POINTER, WVal BLOB SUB_TYPE TEXT = NULL /* Get */) RETURNS BLOB SUB_TYPE TEXT;

  FUNCTION SelfType(Self TY$POINTER = NULL /* NULL - class function */) RETURNS SMALLINT;
  FUNCTION SelfTypeName(Self TY$POINTER = NULL /* NULL - class function */) RETURNS VARCHAR(32);
END
```

Как видно из комментария этот пакет является калькой с класса `TlkJSONbase`. Он содержит базовые функции для работы с JSON.

Функция `Dispose` предназначена для освобождения указателя на JSON объект. Указатели, которые надо принудительно освобождать, появляются в результате парсинга или создания JSON. 
Не следует вызывать его для промежуточных объектов при разборе или сборке JSON. Он требуется только для объекта верхнего уровня.

Функция `Field` возвращает указатель на поле объекта. Первым параметром задаётся указатель на объект, вторым -- имя поля. Если поля не существует, то функция вернёт пустой указатель (Это не NULL, а `x'0000000000000000'`).

Функция `Count_` возвращает количество элементов в списке или полей в объекте. В качестве параметра задаётся указатель на объект или список.

Функция `Child` возвращает или устанавливает значение для элемента с индексом Idx в объекте или списке Self. Если параметр Obj не задан, то возвращает указатель на элемент с индексов Idx.
Если Obj указан, то устанавливает его значение в элемент с индексов Idx. Обратите внимание Obj это указатель на один из потомков TlkJSONbase.

Функция `Value_` возвращает или устанавливает в виде JSON строки (`VARCHAR`) значение для объекта заданного в параметре Self. Если параметр Val не задан, то значение возвращается, в противном случае устанавливается.

Функция `WideValue_` возвращает или устанавливает в виде JSON строки (`BLOB SUB_TYPE TEXT`) значение для объекта заданного в параметре Self. Если параметр Val не задан, то значение возвращается, в противном случае устанавливается.

Функция `SelfType` возвращает тип объекта для указателя заданного в параметре Self. Тип объекта возвращается как число, где

- 0 -- jsBase
- 1 -- jsNumber
- 2 -- jsString
- 3 -- jsBoolean
- 4 -- jsNull
- 5 -- jsList
- 6 -- jsObject

Если параметр Self не задан, то вернёт 0.

Функция `SelfTypeName` возвращает тип объекта для указателя заданного в параметре Self. Тип объекта возвращается как строка. Если параметр Self не задан, то вернёт `'jsBase'`.

### Пакет JS$BOOL

Заголовок этого пакета выглядит следующим образом:

```sql
CREATE OR ALTER PACKAGE JS$BOOL
AS
BEGIN
  /* TlkJSONbase = class
     TlkJSONboolean = class(TlkJSONbase)
  */
  FUNCTION Value_(Self TY$POINTER, Bool BOOLEAN = NULL /* Get */) RETURNS BOOLEAN;

  FUNCTION Generate(Self TY$POINTER = NULL /* NULL - class function */, Bool BOOLEAN = TRUE) RETURNS TY$POINTER;

  FUNCTION SelfType(Self TY$POINTER = NULL /* NULL - class function */) RETURNS SMALLINT;
  FUNCTION SelfTypeName(Self TY$POINTER = NULL /* NULL - class function */) RETURNS VARCHAR(32);
END
```

Как видно из комментария этот пакет является калькой с класса `TlkJSONboolean`. Он предназначен для работы с типом `BOOLEAN`.

Функция `Value_` возвращает или устанавливает в значение логического типа для объекта заданного в параметре Self. Если параметр Bool не задан, то значение будет возвращено, если задан -- установлено.
Обратите внимание, NULL не возвращается и не может быть установлено этим методом, для этого существует отдельный пакет `JS$NULL`.

Функция `Generate` возвращает указатель на объект `TlkJSONboolean`, который представляет собой значение логического типа в JSON.
Параметр Self -- указатель на JSON объект для которого устанавливается значение логическое значение в параметре Bool.
Значение параметра Self будет возращено функцией, если оно отлично от NULL, в противном случае вернёт указатель на новый объект `TlkJSONboolean`.

Функция `SelfType` возвращает тип объекта для указателя заданного в параметре Self. Тип объекта возвращается как число. Если параметр Self не задан, то вернёт 3.

Функция `SelfTypeName` возвращает тип объекта для указателя заданного в параметре Self. Тип объекта возвращается как строка. Если параметр Self не задан, то вернёт `'jsBoolean'`.

### Пакет JS$CUSTLIST

Заголовок этого пакета выглядит следующим образом:

```sql
CREATE OR ALTER PACKAGE JS$CUSTLIST
AS
BEGIN
  /* TlkJSONbase = class
     TlkJSONcustomlist = class(TlkJSONbase)
  */
  PROCEDURE ForEach
    (Self TY$POINTER) RETURNS (Idx Integer, Name VARCHAR(128), Obj TY$POINTER /* js$Base */);

  FUNCTION Field(Self TY$POINTER, Name VARCHAR(128) /* 1..N = Idx */) RETURNS TY$POINTER;
  FUNCTION Count_(Self TY$POINTER) RETURNS INTEGER;
  FUNCTION Child(Self TY$POINTER, Idx INTEGER, Obj TY$POINTER = NULL /* Get */) RETURNS TY$POINTER;

  FUNCTION GetBoolean(Self TY$POINTER, Idx INTEGER) RETURNS BOOLEAN;
  FUNCTION GetDouble(Self TY$POINTER, Idx INTEGER) RETURNS DOUBLE PRECISION;
  FUNCTION GetInteger(Self TY$POINTER, Idx INTEGER) RETURNS INTEGER;
  FUNCTION GetString(Self TY$POINTER, Idx INTEGER) RETURNS VARCHAR(32765);
  FUNCTION GetWideString(Self TY$POINTER, Idx INTEGER) RETURNS BLOB SUB_TYPE TEXT;
END
```

Как видно из комментария этот пакет является калькой с класса `TlkJSONcustomlist`. Этот тип является базовым при работе с объектами и списками.
Все процедуры и функции этого пакета можно использовать как JSON типа объект, так и JSON типа список.

Процедура `ForEach` извлекает каждый элемент списка или каждое поле объекта из указателя на JSON заданного в Self.
Возвращаются следующие значения:
- Idx -- индекс элемента списка или номер поля в объекте. Начинается с 1.
- Name -- имя очередного поля, если Self -- объект. Или индекс элемента списка, начиная с 0, если Self -- список. 
- Obj -- указатель на очередной элемент списка или поля объекта.

Функция `Field` возвращает указатель на поле по его имени из объекта заданного в Self. 
Вместо имени поля можно задать номер элемента в списке или номер поля. Нумерация начинается с 0.

Функция `Count_` возвращает количество элементов в списке или полей в объекте, заданного в параметре Self.

Функция `Child` возвращает или устанавливает значение для элемента с индексом Idx в объекте или списке Self. Индексация начинается с 0. Если параметр Obj не задан, то возвращает указатель на элемент с индексов Idx.
Если Obj указан, то устанавливает его значение в элемент с индексов Idx. Обратите внимание Obj это указатель на один из потомков `TlkJSONbase`.

Функция `GetBoolean` возвращает логическое значение поля объекта или элемента массива с индексом Idx. Индексация начинается с 0.

Функция `GetDouble` возвращает значение с плавающей точкой поля объекта или элемента массива с индексом Idx. Индексация начинается с 0.

Функция `GetInteger` возвращает целочисленное значение поля объекта или элемента массива с индексом Idx. Индексация начинается с 0.

Функция `GetString` возвращает символьное значение (`VARCHAR`) поля объекта или элемента массива с индексом Idx. Индексация начинается с 0.

Функция `GetWideString` возвращает значение типа `BLOB SUN_TYPE TEXT` поля объекта или элемента массива с индексом Idx. Индексация начинается с 0.

Обратите внимание! Функции `GetBoolean`, `GetDouble`, `GetInteger`, `GetString`, `GetWideString` не могу вернуть значение NULL. 
Для обработки значения NULL существует отдельный набор функций в пакете `JS$NULL`.

### Пакет JS$FUNC

Заголовок этого пакета выглядит следующим образом:

```sql
CREATE OR ALTER PACKAGE JS$FUNC
AS
BEGIN
  FUNCTION ParseText(Text BLOB SUB_TYPE TEXT, Conv BOOLEAN = FALSE) RETURNS TY$POINTER;
  FUNCTION ParseString(String VARCHAR(32765), Conv BOOLEAN = FALSE) RETURNS TY$POINTER;

  FUNCTION GenerateText(Obj TY$POINTER, Conv BOOLEAN = FALSE) RETURNS BLOB SUB_TYPE TEXT;
  FUNCTION GenerateString(Obj TY$POINTER, Conv BOOLEAN = FALSE) RETURNS VARCHAR(32765);

  FUNCTION ReadableText(Obj TY$POINTER, Level INTEGER = 0, Conv BOOLEAN = FALSE)
    RETURNS BLOB SUB_TYPE TEXT;
END
```

Этот пакет содержит набор функций для разбора JSON или преобразование JSON в строку.

Функция `ParseText` разбирает JSON заданный в виде строки типа `BLOB SUB_TYPE TEXT` в параметре Text. Если в параметре Conv
передать значение TRUE, то текст JSON строки будет преобразован в кодировку UTF8. Это нужно только когда база данных использует
другую альтернативную кодировку, поскольку внутри JSON может быть только в кодировке UTF8.

Функция `ParseString` разбирает JSON заданный в виде строки типа `VARCHAR(N)` в параметре String. Если в параметре Conv
передать значение TRUE, то текст JSON строки будет преобразован в кодировку UTF8. Это нужно только когда база данных использует
другую альтернативную кодировку, поскольку внутри JSON может быть только в кодировке UTF8.

Функция `GenerateText` возвращает JSON в виде строки типа `BLOB SUB_TYPE TEXT`. Если в параметре Conv передать значение TRUE, 
то текст возвращаемой этой функцией будет преобразован в UTF8. 

Функция `GenerateString` возвращает JSON в виде строки типа `VARCHAR(N)`. Если в параметре Conv передать значение TRUE,
то текст возвращаемой этой функцией будет преобразован в UTF8. 

Функция `ReadableText` возвращает JSON в виде человекочитаемой строки типа `BLOB SUB_TYPE TEXT`. 
Параметр Level - задаёт количество отступов для первого уровня. Это требуется если генерируемая строка является частью другого JSON. 
Если в параметре Conv передать значение TRUE, то текст возвращаемой этой функцией будет преобразован в UTF8. 

### Пакет JS$LIST


## Примеры

### Разбор JSON 

Предположим у вас есть JSON в котором содержится список людей с их характеристиками.

Этот JSON выглядит следующим образом:

```json
[
  {"id": 1, "name": "Вася"}, 
  {"id": 2, "name": null}
]
```

Напишем хранимую процедуру, которая возвращает список людей из этого JSON

```sql
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
  -- Опять же функции из этой библиотеки не проверяют корректность типов эелементов
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
    -- Проверяем, что эелемент массива - это объект, иначе
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
```

Для проверки правильности выполните следующий запрос

```sql
select id, name
from parse_peoples_json( '[{"id": 1, "name": "Вася"}, {"id": 2, "name": null}]' )
```