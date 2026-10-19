# TP Unidad 4 — FNBC y Desnormalización Controlada en Food Store

**Materia:** Base de Datos II — Tecnicatura Universitaria en Programación
**Motor:** PostgreSQL 17.11
**Base de trabajo:** `foodstore_u4` (copia de `foodstore_u3_tp`, ya poblada): 10 categorías, 50.000 productos, 200.000 pedidos, 600.000 líneas de `detalle_pedido`.

> **Nota sobre la consulta del enunciado (5.1).** El esquema real de Food Store no tiene las columnas `subtotal` ni `eliminado` en `detalle_pedido` (solo `cantidad` y `precio_unitario`; el borrado lógico vive en `pedido.eliminado`). Por eso la consulta se ejecuta como `SUM(dp.cantidad * dp.precio_unitario)` y sin el filtro `dp.eliminado`. El plan de ejecución y el costo son los mismos.

> **Nota sobre el día de medición.** La base sembrada no contiene pedidos con `fecha = CURRENT_DATE` (su rango va de 2025-01-01 a 2026-09-22). El día se parametriza y se mide sobre **2025-04-24**, el día con mayor volumen: 398 pedidos no eliminados y 1.672 líneas de detalle.

---

## Parte 1 — Análisis y aplicación de la FNBC: `control_lote_almacen`

Entregable completo: **`tp_fnbc_control_lote.sql`** (ejecutado y verificado sobre `foodstore_u4`).

### a) Dependencias funcionales

De la regla de negocio se desprenden exactamente dos dependencias funcionales:

- **FD1 (la clave primaria):** `LoteID, DepositoID → ResponsableControlID`
  *"Para un lote y un depósito intervinientes dados, el responsable de control queda unívocamente determinado."*
- **FD2:** `ResponsableControlID → DepositoID`
  *"Cada responsable de control pertenece, como dato maestro de la dotación de personal, a un único depósito: no controla lotes coordinados desde depósitos distintos."* Dado un responsable, su depósito queda determinado.

No hay otras FDs: de la regla no se extrae ninguna otra determinación unívoca (`LoteID → DepositoID` sería falsa: un mismo lote se controla desde más de un depósito).

### b) Clausuras de atributos y claves candidatas

Clausuras (aplicando FD1 y FD2 en sucesión hasta alcanzar el punto fijo):

| Subconjunto | Clausura | ¿Superclave? |
|---|---|---|
| `{LoteID}` | `{LoteID}` | No |
| `{DepositoID}` | `{DepositoID}` | No |
| `{ResponsableControlID}` | `{ResponsableControlID, DepositoID}` | No (falta `LoteID`) |
| `{DepositoID, ResponsableControlID}` | `{DepositoID, ResponsableControlID}` | No (ninguna FD aporta `LoteID`) |
| `{LoteID, DepositoID}` | `{LoteID, DepositoID, ResponsableControlID}` = todos | **Sí** |
| `{LoteID, ResponsableControlID}` | `{LoteID, ResponsableControlID}` + FD2 → `DepositoID` → todos | **Sí** |

Detalle del cálculo que produce la segunda clave: partiendo de `{LoteID, ResponsableControlID}`, la FD2 (`ResponsableControlID → DepositoID`) agrega `DepositoID`; con `{LoteID, DepositoID}` completos, la FD1 ya está satisfecha (el atributo determinado ya está en la clausura) y el punto fijo es el conjunto universal.

**Conjunto completo de claves candidatas:**

- `K1 = {LoteID, DepositoID}` (es la clave primaria del esquema dado)
- `K2 = {LoteID, ResponsableControlID}`

**Atributos primos:** los tres: `LoteID`, `DepositoID`, `ResponsableControlID` (cada uno pertenece a alguna clave candidata).
**Atributos no primos:** ninguno.

Verificación empírica de K2 sobre la instancia (0 filas duplicadas ⇒ es clave también en los datos):

```sql
SELECT lote_id, responsable_control_id, COUNT(*) AS repeticiones
FROM   control_lote_almacen
GROUP  BY lote_id, responsable_control_id
HAVING COUNT(*) > 1;     -- 0 filas
```

### c) ¿Cumple FNBC?

**No.** La definición formal de Forma Normal de Boyce-Codd exige:

> Para toda dependencia funcional `X → A` de R, `X` debe ser superclave de R.

Aplicada a la FD2 `ResponsableControlID → DepositoID`:

- Su determinante es `{ResponsableControlID}`.
- Su clausura es `{ResponsableControlID, DepositoID}` ≠ conjunto universal de la relación.
- Por lo tanto **`ResponsableControlID` no es superclave** y la FD2 viola FNBC. Es la única FD violatoria: la FD1 tiene como determinante a `K1`, que sí es superclave (de hecho, clave candidata).

**Dato interesante (por qué el TP pide FNBC y no 3FN):** como todos los atributos del esquema son primos, la relación **sí está en 3FN** (ningún atributo no-primo depende parcial o transitivamente de una clave) y también en 2FN. La FNBC es estrictamente más exigente: prohíbe determinantes que no sean superclave aunque lo que determinen sean atributos primos. Este esquema es el ejemplo canónico de "está en 3FN pero no en FNBC".

### d) Las tres anomalías clásicas, sobre la instancia de ejemplo

Instancia cargada: `(501, 30, 801)`, `(502, 30, 801)`, `(503, 31, 802)`.

**Anomalía de inserción.** El hecho "el responsable 803 pertenece al depósito 32" es un dato maestro de la dotación de personal que debería poder registrarse por sí solo. En `control_lote_almacen` no existe forma de hacerlo: `lote_id` es `NOT NULL` y además forma parte de la clave primaria, así que para registrar la pertenencia de un responsable a un depósito hay que *inventar* un lote (o un par lote-depósito ficticio). El esquema sólo permite registrar la asignación responsable-depósito "a costo de" crear un control de lote que en la realidad no existe.

**Anomalía de borrado.** Si se borra la fila `(503, 31, 802)` — por ejemplo, porque el lote 503 fue anulado —, junto con ella desaparece la información "el responsable 802 pertenece al depósito 31", que es un dato maestro que debería sobrevivir a cualquier cambio en los lotes. Es la última fila en la que aparece 802, y el depósito al que pertenece queda irrecuperable en esa tabla.

**Anomalía de actualización.** Si el responsable 801 se muda al depósito 31, hay que actualizar **las dos filas** en las que aparece (501,30,801) y (502,30,801). La redundancia que impone la FD2 hace que un update parcial (o dos transacciones concurrentes que actualicen una fila cada una) deje la base en estado contradictorio: 801 aparecería asociado al depósito 30 en una fila y al 31 en otra, violando la regla de negocio sin que ninguna restricción lo impida. La prueba directa de la redundancia:

```sql
SELECT responsable_control_id,
       COUNT(DISTINCT deposito_id) depositos_distintos,
       COUNT(*)                    filas_almacenadas
FROM   control_lote_almacen
GROUP  BY responsable_control_id
HAVING COUNT(*) > 1;
--  responsable_control_id | depositos_distintos | filas_almacenadas
-- ------------------------+---------------------+-------------------
--                     801 |                   1 |                 2
```

El par `(801, 30)` está almacenado dos veces: la tabla no tiene ninguna clave que lo cubra una sola vez.

### e) Descomposición sin pérdida y script SQL

Algoritmo aplicado: para cada FD `X → Y` que viola FNBC, extraer una tabla `R(Y, X)` cuya clave primaria sea `X`, y dejar en la tabla restante `R(R − Y, X)` la clave que sí es superclave. Aplicado a la única FD violatoria (`ResponsableControlID → DepositoID`):

- **R1** = `control_lote_responsable (LoteID, ResponsableControlID)` — PK `(LoteID, ResponsableControlID)`; contiene la FD1.
- **R2** = `deposito_responsable (ResponsableControlID, DepositoID)` — PK `ResponsableControlID`; contiene la FD2, y su determinante es ahora superclave (es la PK), con lo que R2 cumple FNBC.
- R1 también cumple FNBC: su única FD es la propia clave.

```sql
CREATE TABLE control_lote_responsable (
    lote_id                 BIGINT NOT NULL REFERENCES lote (id),
    responsable_control_id  BIGINT NOT NULL REFERENCES usuario (id),
    PRIMARY KEY (lote_id, responsable_control_id)
);

CREATE TABLE deposito_responsable (
    responsable_control_id  BIGINT PRIMARY KEY REFERENCES usuario (id),
    deposito_id             BIGINT NOT NULL REFERENCES deposito (id)
);

-- Vista de compatibilidad: reconstruye la relación original
CREATE VIEW control_lote_almacen_compat AS
SELECT lr.lote_id,
       dr.deposito_id,
       lr.responsable_control_id
FROM   control_lote_responsable lr
JOIN   deposito_responsable     dr USING (responsable_control_id);

-- Migración de la instancia de ejemplo
INSERT INTO control_lote_responsable (lote_id, responsable_control_id)
SELECT DISTINCT lote_id, responsable_control_id FROM control_lote_almacen;

INSERT INTO deposito_responsable (responsable_control_id, deposito_id)
SELECT DISTINCT responsable_control_id, deposito_id FROM control_lote_almacen;
```

El script completo (con las tablas maestras `lote` y `deposito`, la instancia original, la migración y la eliminación final de la tabla que violaba FNBC) está en `tp_fnbc_control_lote.sql`.

### f) Justificación de la unión sin pérdida y verificación

**Criterio de superclave sobre el atributo común.** El teorema de pérdida de unión establece que, para una descomposición `R = R1 ∩ R2`, la reconstrucción por unión natural es sin pérdida si el atributo común determina alguna de las componentes; es decir, si `R1 ∩ R2 → R2 − R1` (o `R1 ∩ R2 → R1 − R2`) es una dependencia funcional válida en R. Aquí:

- `R1 ∩ R2 = {ResponsableControlID}`
- `R2 − R1 = {DepositoID}`
- La FD2 `ResponsableControlID → DepositoID` es una FD del esquema original. Luego **la unión natural es sin pérdida**.

Intuitivamente: como en R2 el atributo común `ResponsableControlID` **es clave primaria**, cada fila de R1 se junta con **exactamente una** fila de R2 (o con ninguna si el par no existe); nunca se "multiplican" filas ni se pierden combinaciones, porque toda combinación posible de la relación original está determinada por el responsable.

**Migración y verificación.** Los datos se migraron y la equivalencia se comprobó en ambos sentidos con la vista de compatibilidad; las dos diferencias devolvieron 0 filas:

```sql
-- (a) filas de la vista que no están en la relación original -> 0 filas
SELECT * FROM (SELECT * FROM control_lote_almacen_compat
               EXCEPT
               SELECT * FROM control_lote_almacen) d;

-- (b) filas de la relación original que no están en la vista -> 0 filas
SELECT * FROM (SELECT * FROM control_lote_almacen
               EXCEPT
               SELECT * FROM control_lote_almacen_compat) d;
```

Resultado final sobre la instancia (la redundancia 801→30 quedó almacenada una sola vez):

| control_lote_responsable | | deposito_responsable | | vista de compatibilidad | |
|---|---|---|---|---|---|
| lote_id | resp_id | resp_id | deposito_id | lote_id | deposito_id | resp_id |
| 501 | 801 | 801 | 30 | 501 | 30 | 801 |
| 502 | 801 | 802 | 31 | 502 | 30 | 801 |
| 503 | 802 | | | 503 | 31 | 802 |

Las anomalías de la d) quedan resueltas: el pertenecer a un depósito es ahora una fila propia (inserción), su borrado no arrastra lotes (borrado), y el responsable 801 aparece **una sola vez** con su depósito (actualización).

---

## Parte 2 — Consulta con desnormalización controlada

Entregable completo: **`tp_desnormalizacion_top_categorias.sql`** (ejecutado y verificado sobre `foodstore_u4`).

### a) EXPLAIN ANALYZE de la consulta original

Consulta del enunciado adaptada al esquema real (ver nota inicial), sobre el día 2025-04-24:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre AS categoria,
       SUM(dp.cantidad * dp.precio_unitario) AS total_vendido
FROM   detalle_pedido dp
JOIN   producto pr  ON pr.id = dp.producto_id
JOIN   categoria c  ON c.id  = pr.categoria_id
JOIN   pedido ped   ON ped.id = dp.pedido_id
WHERE  ped.fecha >= DATE '2025-04-24'
  AND  ped.fecha <  DATE '2025-04-25'
  AND  ped.eliminado = FALSE
GROUP  BY c.nombre
ORDER  BY total_vendido DESC
LIMIT  5;
```

Salida (fragmento relevante):

```
Limit  (cost=9840.65..9840.67 rows=5 width=40) (actual time=57.707..62.023 rows=5 loops=1)
  Buffers: shared hit=7826 read=2593
  ->  Finalize GroupAggregate ...
        ->  Gather Merge  (Workers Planned: 2, Workers Launched: 2)
              ->  Partial GroupAggregate
                    ->  Hash Join  (Hash Cond: (pr.categoria_id = c.id))
                          ->  Nested Loop
                                ->  Hash Join  (Hash Cond: (dp.pedido_id = ped.id))
                                      ->  Parallel Seq Scan on detalle_pedido dp
                                            (actual time=0.321..13.764 rows=200000 loops=3)
                                      ->  Bitmap Heap Scan on pedido ped (398 filas)
                                ->  Index Scan using producto_pkey on producto pr
                                      (actual time=0.006..0.006 rows=1 loops=1672)
Planning Time: 8.658 ms
Execution Time: 62.276 ms
```

- **Tiempo de ejecución:** **≈ 50–62 ms** por corrida (promedios repetidos: 62,3 / 50,3 / 49,7 / 52,0 / 51,7 ms).
- **Nodo que domina el costo:** el **`Parallel Seq Scan` sobre `detalle_pedido`**: lee **las 600.000 líneas de la tabla** (200.000 filas × 3 procesos en paralelo) para filtrar después las 1.672 líneas que realmente pertenecen al día. Es el nodo con mayor costo acumulado (`cost=7079` de un total de ~8.837 en el subárbol) y, junto a los **1.672 `Index Scan` sobre `producto_pkey`** que lo alimentan (≈ 5.000 buffers), concentra casi todas las lecturas del plan: `shared hit=7826 read=2593` (**≈ 10.400 buffers ≈ 83 MB** por cada ejecución del panel).

Es exactamente el síntoma que describe el enunciado: el reporte consulta pocas filas del día, pero el plan no tiene dónde "pararse" y recorre entero el detalle (más 1.672 accesos individuales a `producto`) por cada invocación.

### b) Patrón elegido: tabla resumen mantenida con disparadores

**Elección: tabla resumen precalculada (`venta_categoria_diaria`) mantenida por disparadores**, no vista materializada.

1. **Qué evidencia motiva la decisión.** El plan de a) domina el `Parallel Seq Scan` sobre `detalle_pedido` (600.000 filas leídas, ~83 MB de buffers) para producir 10 grupos. La información que el panel necesita —monto y cantidad de líneas por categoría y día— es **función determinística** de la fuente, y su volumen real es minúsculo: 10 categorías × 2.814 días = 28.140 filas agregadas contra 600.000 filas de detalle. Precalcularlas elimina por completo el recorrido y las reuniones.
2. **Qué garantiza que el dato redundante no se desincronice.** La única vía de escritura de la tabla resumen es `fn_recalculo_venta_categoria(fecha)`, que **borra y recalcula el día completo desde la fuente de verdad**; los disparadores la invocan ante cualquier cambio que pueda alterar el reporte: `INSERT`/`UPDATE`/`DELETE` sobre `detalle_pedido` (nivel sentencia, con tablas de transición: se recalculan los días de los pedidos afectados, en ambos lados de un `UPDATE`) y `UPDATE` de `pedido.fecha` o `pedido.eliminado` (nivel fila). Como el cálculo siempre parte de cero desde el origen y es atómico (borrado + inserción en la misma transacción), no puede acumular desvíos parciales; y cada INSERT/UPDATE/DELETE sobre `detalle_pedido` dispara **un único DELETE+INSERT sobre ~10 filas del día** (índice por `(fecha, total_vendido)`), costo constante e imperceptible para el escritor. Además, el script de auditoría de (e) comprueba periódicamente la igualdad con la fuente.
3. **¿Es reversible sin pérdida?** Sí. No se modificó ninguna fila ni columna del esquema original: los objetos creados son puramente aditivos (una tabla nueva, un índice, funciones y disparadores). La reversión consiste en `DROP` de esos objetos (script de reversa incluido en el archivo, sección [8]) y el reporte vuelve a resolverse con la consulta normalizada, con idéntico resultado. **Nada que re-sincronizar, porque la fuente de verdad nunca se tocó.**

Una vista materializada descartada: `REFRESH MATERIALIZED VIEW` recalcula todo el histórico (no el día), es una operación pesada que no puede ejecutarse con frecuencia, y sin `CONCURRENTLY` deja la vista ilegible durante el refresh; `CONCURRENTLY` exige índice único, rehace todo el barrido igual y aun así sólo garantiza consistencia al final del refresh. Para un panel que se consulta muchas veces por minuto y exige dato en tiempo real, la tabla resumen con disparadores es el patrón correcto.

### c) Implementación (script completo)

En `tp_desnormalizacion_top_categorias.sql`, secciones [2] a [4]:

```sql
CREATE TABLE venta_categoria_diaria (
    fecha           DATE NOT NULL,
    categoria_id    INTEGER NOT NULL REFERENCES categoria (id),
    total_vendido   NUMERIC(14,2) NOT NULL DEFAULT 0,
    cantidad_lineas BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (fecha, categoria_id)
);
CREATE INDEX idx_venta_categoria_diaria_fecha_total
    ON venta_categoria_diaria (fecha, total_vendido DESC);

-- Recalcula un día completo desde la fuente de verdad
CREATE OR REPLACE FUNCTION fn_recalculo_venta_categoria (p_fecha DATE)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM venta_categoria_diaria v WHERE v.fecha = p_fecha;
    INSERT INTO venta_categoria_diaria (fecha, categoria_id, total_vendido, cantidad_lineas)
    SELECT   ped.fecha::date, pr.categoria_id,
             SUM (dp.cantidad * dp.precio_unitario), COUNT (*)
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id = dp.producto_id
    WHERE    ped.fecha >= p_fecha AND ped.fecha < p_fecha + 1
    GROUP BY 1, 2;
END; $$;
```

Disparadores: tres sobre `detalle_pedido` (`AFTER INSERT`, `AFTER UPDATE`, `AFTER DELETE` a nivel sentencia con tablas de transición —PostgreSQL no permite varios eventos con tablas de transición en un único trigger—) y uno sobre `pedido` (`AFTER UPDATE ... WHEN (OLD.fecha IS DISTINCT FROM NEW.fecha OR OLD.eliminado IS DISTINCT FROM NEW.eliminado)`), todos delegando en `fn_recalculo_venta_categoria` sobre los días involucrados. La carga histórica (backfill) se hizo con un único barrido agregado:

```sql
INSERT INTO venta_categoria_diaria (fecha, categoria_id, total_vendido, cantidad_lineas)
SELECT   ped.fecha::date, pr.categoria_id,
         SUM (dp.cantidad * dp.precio_unitario), COUNT (*)
FROM     detalle_pedido dp
JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
JOIN     producto pr ON pr.id = dp.producto_id
GROUP BY 1, 2;
-- 2.814 filas-día-categoría, 590.000 líneas cubiertas (2025-01-01 a 2026-09-22)
```

**Demostración de sincronización en vivo** (incluida en el script, sección [6]): se inserta una línea de 50 unidades de la categoría *Bebidas* en un pedido del día medido y el resumen queda actualizado en el mismo instante (`Bebidas: 2.579.813,60 → 2.623.348,60`; líneas 318 → 319); al borrar la línea, el trigger de `DELETE` devuelve el resumen al valor original exacto.

### d) Consulta desde la estructura desnormalizada y comparación

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre              AS categoria,
       v.total_vendido
FROM   venta_categoria_diaria v
JOIN   categoria c ON c.id = v.categoria_id
WHERE  v.fecha = DATE '2025-04-24'
ORDER  BY v.total_vendido DESC
LIMIT  5;
```

```
Limit  (cost=0.28..21.67 rows=5 width=16) (actual time=0.015..0.020 rows=5 loops=1)
  Buffers: shared hit=7
  ->  Nested Loop (Join Filter: (v.categoria_id = c.id), Rows Removed by Join Filter: 30)
        ->  Index Scan using idx_venta_categoria_diaria_fecha_total on venta_categoria_diaria v
              (actual time=0.003..0.004 rows=5 loops=1)
              Index Cond: (fecha = '2025-04-24'::date)
        ->  Materialize  (rows=7 loops=5)
              ->  Seq Scan on categoria c (10 filas)
Planning Time: 0.148 ms
Execution Time: 0.029 ms
```

El resultado es idéntico al de la consulta original (mismas 5 categorías y montos). Tabla comparativa:

| | ANTES (normalizada) | DESPUÉS (desnormalizada) |
|---|---|---|
| **Tiempo de ejecución** | **50,3 ms** (promedio de corridas: 49,7 – 62,3 ms) | **0,029 ms** (corridas repetidas: 0,029 – 0,117 ms) |
| **Tipo de nodo dominante** | `Parallel Seq Scan` sobre `detalle_pedido` (600.000 filas leídas) + 1.672 `Index Scan` sobre `producto_pkey` | `Index Scan` sobre `idx_venta_categoria_diaria_fecha_total` (5 filas) |
| **Buffers (hit / read)** | 7.826 / 2.593 (≈ 83 MB) | 7 / 0 (≈ 56 KB) |
| **Filas leídas del detalle** | 600.000 | 0 |

**Ganancia: ~1.700× (dos órdenes de magnitud).** El plan pasó de recorrer entero el detalle y reunir cuatro tablas a un rango de índice de 5 filas sobre la tabla resumen más una materialización de las 10 categorías.

### e) Script de auditoría de desincronización

Compara la fuente de verdad con el dato redundante en ambos sentidos (filas que faltan, filas que sobran y valores distintos) usando un `FULL JOIN` entre el agregado recalculado al vuelo y la tabla resumen:

```sql
WITH esperado AS (
    SELECT   ped.fecha::date AS fecha, pr.categoria_id,
             SUM (dp.cantidad * dp.precio_unitario) AS total_vendido,
             COUNT (*)       AS cantidad_lineas
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id  = dp.producto_id
    GROUP BY 1, 2
),
almacenado AS (
    SELECT fecha, categoria_id, total_vendido, cantidad_lineas
    FROM   venta_categoria_diaria
)
-- ... FULL JOIN + condiciones de desvío (ver archivo, sección [7])
```

Resultado sobre la base ya migrada (2.814 filas agregadas vs. la fuente completa): **0 filas de desincronización**, tal como exige el enunciado.

Como prueba de que la auditoría funciona, el script incluye una sección que fuerza un desvío (suma 1 a los totales del día medido) y la auditoría detecta las 9 filas alteradas; luego se repara con la única vía de escritura válida (`fn_recalculo_venta_categoria('2025-04-24')`) y el contador de desvíos vuelve a **0**.

---

## Entregables

1. `tp_fnbc_control_lote.sql` — esquema inicial + instancia, verificación de claves, descomposición sin pérdida, vista de compatibilidad y migración verificada (Parte 1).
2. `tp_desnormalizacion_top_categorias.sql` — estructura desnormalizada, mecanismo de sincronización (funciones + disparadores), backfill, consulta optimizada con `EXPLAIN ANALYZE`, demostración de sincronización y auditoría (Parte 2).
3. Este informe (`informe_TPU4_FNBC_Desnormalizacion.docx` / `.md`).
