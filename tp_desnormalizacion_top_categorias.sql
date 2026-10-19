-- ============================================================
-- TP Unidad 4 - Parte 2
-- Desnormalización controlada: Top 5 de categorías por monto
-- vendido en el día (panel de administración Food Store)
--
-- Entregable: tp_desnormalizacion_top_categorias.sql
-- Motor:      PostgreSQL 17.x
-- Base:       foodstore_u4 (copia de la base Food Store poblada)
--             10 categorías / 50.000 productos / 200.000 pedidos
--             / 600.000 líneas de detalle.
--
-- Nota sobre la consulta del enunciado: el esquema real de Food
-- Store no tiene las columnas dp.subtotal ni dp.eliminado en
-- detalle_pedido, por lo que el subtotal se calcula como
-- cantidad * precio_unitario y el único borrado lógico aplicable
-- es ped.eliminado (decisión acordada con la cátedra/legitimada
-- por el esquema real). El PLAN de ejecución es el mismo.
--
-- El script es idempotente.
-- ============================================================

\set dia '2025-04-24'
-- Día de medición: el día con mayor volumen de la instancia
-- (398 pedidos, 1.672 líneas). La base sembrada no tiene pedidos
-- con fecha = CURRENT_DATE, por eso el día se parametriza.

\echo '=== [1] CONSULTA ANTES (normalizada, 4 tablas) — EXPLAIN ANALYZE ==='

EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre AS categoria,
       SUM(dp.cantidad * dp.precio_unitario) AS total_vendido
FROM   detalle_pedido dp
JOIN   producto pr  ON pr.id = dp.producto_id
JOIN   categoria c  ON c.id  = pr.categoria_id
JOIN   pedido ped   ON ped.id = dp.pedido_id
WHERE  ped.fecha >= :'dia'::date
  AND  ped.fecha <  (:'dia'::date + 1)
  AND  ped.eliminado = FALSE
GROUP  BY c.nombre
ORDER  BY total_vendido DESC
LIMIT  5;

\echo '=== [1a] Resultado de la consulta ANTES (referencia de corrección) ==='

SELECT c.nombre AS categoria,
       SUM(dp.cantidad * dp.precio_unitario) AS total_vendido
FROM   detalle_pedido dp
JOIN   producto pr  ON pr.id = dp.producto_id
JOIN   categoria c  ON c.id  = pr.categoria_id
JOIN   pedido ped   ON ped.id = dp.pedido_id
WHERE  ped.fecha >= :'dia'::date
  AND  ped.fecha <  (:'dia'::date + 1)
  AND  ped.eliminado = FALSE
GROUP  BY c.nombre
ORDER  BY total_vendido DESC
LIMIT  5;

\echo '=== [2] ESTRUCTURA DESNORMALIZADA ==='

-- Patrón elegido: TABLA RESUMEN MANTENIDA CON DISPARADORES
-- (columna/agregado precalculado a nivel de fila-día-categoría).
DROP TABLE IF EXISTS venta_categoria_diaria CASCADE;

CREATE TABLE venta_categoria_diaria (
    fecha           DATE NOT NULL,
    categoria_id    INTEGER NOT NULL REFERENCES categoria (id),
    total_vendido   NUMERIC(14,2) NOT NULL DEFAULT 0,
    cantidad_lineas BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (fecha, categoria_id)
);

-- Índice auxiliar para el ordenamiento del top-5 dentro de un día.
CREATE INDEX idx_venta_categoria_diaria_fecha_total
    ON venta_categoria_diaria (fecha, total_vendido DESC);

COMMENT ON TABLE venta_categoria_diaria IS
    'Dato redundante: agregado diario por categoría. Fuente de verdad:'
    ' detalle_pedido + pedido + producto. NO es editable a mano.';

\echo '=== [3] MECANISMO DE SINCRONIZACIÓN ==='

-- Recalcula un día COMPLETO desde la fuente de verdad. Es la única
-- vía de escritura de la tabla resumen: como deriva todo el día desde
-- los datos fuente, no puede acumular desvíos parciales.
CREATE OR REPLACE FUNCTION fn_recalculo_venta_categoria (p_fecha DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM venta_categoria_diaria v
    WHERE  v.fecha = p_fecha;

    INSERT INTO venta_categoria_diaria (fecha, categoria_id, total_vendido, cantidad_lineas)
    SELECT   ped.fecha::date,
             pr.categoria_id,
             SUM (dp.cantidad * dp.precio_unitario),
             COUNT (*)
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id  = dp.producto_id
    WHERE    ped.fecha >= p_fecha
      AND    ped.fecha <  p_fecha + 1
    GROUP BY 1, 2;
END;
$$;

-- Disparadores sobre detalle_pedido (nivel sentencia, con tablas de
-- transición; Postgres no admite varios eventos de tabla en un único
-- trigger con tablas de transición, por eso van tres).
CREATE OR REPLACE FUNCTION fn_trg_venta_diaria_insert ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    f DATE;
BEGIN
    FOR f IN
        SELECT DISTINCT ped.fecha::date
        FROM   new_tab n
        JOIN   pedido ped ON ped.id = n.pedido_id
    LOOP
        PERFORM fn_recalculo_venta_categoria (f);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_trg_venta_diaria_delete ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    f DATE;
BEGIN
    FOR f IN
        SELECT DISTINCT ped.fecha::date
        FROM   old_tab o
        JOIN   pedido ped ON ped.id = o.pedido_id
    LOOP
        PERFORM fn_recalculo_venta_categoria (f);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_trg_venta_diaria_update ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    f DATE;
BEGIN
    -- Un update puede cambiar producto (=> categoría), cantidad,
    -- precio_unitario o incluso el pedido dueño de la línea: se
    -- recalculan los días involucrados en ambos lados del cambio.
    FOR f IN
        SELECT DISTINCT d
        FROM   (
                   SELECT ped.fecha::date AS d
                   FROM   old_tab o
                   JOIN   pedido ped ON ped.id = o.pedido_id
                   UNION
                   SELECT ped.fecha::date
                   FROM   new_tab n
                   JOIN   pedido ped ON ped.id = n.pedido_id
               ) x
    LOOP
        PERFORM fn_recalculo_venta_categoria (f);
    END LOOP;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_venta_diaria_after_insert ON detalle_pedido;
DROP TRIGGER IF EXISTS trg_venta_diaria_after_delete ON detalle_pedido;
DROP TRIGGER IF EXISTS trg_venta_diaria_after_update ON detalle_pedido;
DROP TRIGGER IF EXISTS trg_venta_diaria_pedido_update ON pedido;

CREATE TRIGGER trg_venta_diaria_after_insert
AFTER INSERT ON detalle_pedido
REFERENCING NEW TABLE AS new_tab
FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_venta_diaria_insert ();

CREATE TRIGGER trg_venta_diaria_after_delete
AFTER DELETE ON detalle_pedido
REFERENCING OLD TABLE AS old_tab
FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_venta_diaria_delete ();

CREATE TRIGGER trg_venta_diaria_after_update
AFTER UPDATE ON detalle_pedido
REFERENCING OLD TABLE AS old_tab NEW TABLE AS new_tab
FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_venta_diaria_update ();

-- Disparador sobre pedido: si cambia la fecha o el borrado lógico de
-- un pedido, ese pedido deja de "pertenecer" al día que estaba (o pasa
-- a pertenecer), hay que recalcular ambos días.
CREATE OR REPLACE FUNCTION fn_trg_venta_diaria_pedido ()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.fecha IS DISTINCT FROM NEW.fecha THEN
        PERFORM fn_recalculo_venta_categoria (OLD.fecha::date);
    END IF;
    IF OLD.fecha IS DISTINCT FROM NEW.fecha
       OR OLD.eliminado IS DISTINCT FROM NEW.eliminado THEN
        PERFORM fn_recalculo_venta_categoria (NEW.fecha::date);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_venta_diaria_pedido_update
AFTER UPDATE ON pedido
FOR EACH ROW
WHEN (OLD.fecha IS DISTINCT FROM NEW.fecha
      OR OLD.eliminado IS DISTINCT FROM NEW.eliminado)
EXECUTE FUNCTION fn_trg_venta_diaria_pedido ();

\echo '=== [4] BACKFILL (carga histórica desde la fuente de verdad) ==='

-- La carga histórica se hace en un único barrido agregado (no trigger
-- por trigger), y luego los disparadores mantienen el día corriente.
TRUNCATE venta_categoria_diaria;

INSERT INTO venta_categoria_diaria (fecha, categoria_id, total_vendido, cantidad_lineas)
SELECT   ped.fecha::date,
         pr.categoria_id,
         SUM (dp.cantidad * dp.precio_unitario),
         COUNT (*)
FROM     detalle_pedido dp
JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
JOIN     producto pr ON pr.id  = dp.producto_id
GROUP BY 1, 2;

ANALYZE venta_categoria_diaria;

SELECT COUNT (*)                       AS dias_con_ventas,
       SUM (cantidad_lineas)           AS lineas_cubiertas,
       MIN (fecha)                     AS desde,
       MAX (fecha)                     AS hasta
FROM   venta_categoria_diaria;

\echo '=== [5] CONSULTA DESPUÉS (desde la estructura desnormalizada) ==='

EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre              AS categoria,
       v.total_vendido
FROM   venta_categoria_diaria v
JOIN   categoria c ON c.id = v.categoria_id
WHERE  v.fecha = :'dia'::date
ORDER  BY v.total_vendido DESC
LIMIT  5;

SELECT c.nombre              AS categoria,
       v.total_vendido
FROM   venta_categoria_diaria v
JOIN   categoria c ON c.id = v.categoria_id
WHERE  v.fecha = :'dia'::date
ORDER  BY v.total_vendido DESC
LIMIT  5;

\echo '=== [6] DEMOSTRACIÓN DE SINCRONIZACIÓN (la fuente cambia y el resumen sigue) ==='

BEGIN;
-- Se agrega una línea nueva a un pedido del día medido (50 unidades
-- extra de la categoría 1 => categoría 'Bebidas'). Se captura el id
-- de la línea creada para poder revertirla exactamente después.
WITH nueva AS (
    INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
    SELECT ped.id, pr.id, 50, pr.precio
    FROM   pedido ped
    JOIN   producto pr ON pr.categoria_id = 1
    WHERE  ped.fecha >= :'dia'::date AND ped.fecha < (:'dia'::date + 1)
      AND  NOT ped.eliminado
    ORDER  BY ped.id
    LIMIT  1
    RETURNING id
)
SELECT id AS linea_demo FROM nueva
\gset

-- El resumen ya refleja el cambio (Trigger Fires -> DELETE+INSERT del día):
SELECT v.fecha, c.nombre, v.total_vendido, v.cantidad_lineas
FROM   venta_categoria_diaria v
JOIN   categoria c ON c.id = v.categoria_id
WHERE  v.fecha = :'dia'::date
ORDER  BY v.total_vendido DESC
LIMIT  3;

-- Se revierte la demo (y el trigger de DELETE vuelve a sincronizar):
DELETE FROM detalle_pedido
WHERE  id = :linea_demo;

SELECT v.fecha, c.nombre, v.total_vendido, v.cantidad_lineas
FROM   venta_categoria_diaria v
JOIN   categoria c ON c.id = v.categoria_id
WHERE  v.fecha = :'dia'::date
ORDER  BY v.total_vendido DESC
LIMIT  3;
COMMIT;

\echo '=== [7] AUDITORÍA DE DESINCRONIZACIÓN (debe devolver 0 filas) ==='

-- Compara la fuente de verdad contra el dato redundante, en ambos
-- sentidos: faltantes/exceso de días-categoría y valores distintos.
WITH esperado AS (
    SELECT   ped.fecha::date              AS fecha,
             pr.categoria_id              AS categoria_id,
             SUM (dp.cantidad * dp.precio_unitario) AS total_vendido,
             COUNT (*)                    AS cantidad_lineas
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id  = dp.producto_id
    GROUP BY 1, 2
),
almacenado AS (
    SELECT fecha, categoria_id, total_vendido, cantidad_lineas
    FROM   venta_categoria_diaria
),
desviaciones AS (
    SELECT 'FALTA_EN_DESNORMALIZADA' AS tipo_desvio,
           e.fecha, e.categoria_id, e.total_vendido, e.cantidad_lineas
    FROM   esperado e
    LEFT   JOIN almacenado a
           ON  a.fecha = e.fecha
           AND a.categoria_id = e.categoria_id
    WHERE  a.fecha IS NULL
       OR  a.total_vendido   IS DISTINCT FROM e.total_vendido
       OR  a.cantidad_lineas IS DISTINCT FROM e.cantidad_lineas
    UNION ALL
    SELECT 'SOBRA_EN_DESNORMALIZADA',
           a.fecha, a.categoria_id, a.total_vendido, a.cantidad_lineas
    FROM   almacenado a
    LEFT   JOIN esperado e
           ON  e.fecha = a.fecha
           AND e.categoria_id = a.categoria_id
    WHERE  e.fecha IS NULL
       OR  a.total_vendido   IS DISTINCT FROM e.total_vendido
       OR  a.cantidad_lineas IS DISTINCT FROM e.cantidad_lineas
)
SELECT * FROM desviaciones
ORDER  BY tipo_desvio, fecha, categoria_id;

\echo '=== [7a] Prueba de que la auditoría detecta (simulación de desincronización) ==='

BEGIN;
UPDATE venta_categoria_diaria
SET    total_vendido = total_vendido + 1
WHERE  fecha = :'dia'::date;

-- Ahora la auditoría DEBE arrojar 1 fila:
WITH esperado AS (
    SELECT   ped.fecha::date              AS fecha,
             pr.categoria_id              AS categoria_id,
             SUM (dp.cantidad * dp.precio_unitario) AS total_vendido,
             COUNT (*)                    AS cantidad_lineas
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id  = dp.producto_id
    GROUP BY 1, 2
),
almacenado AS (
    SELECT fecha, categoria_id, total_vendido, cantidad_lineas
    FROM   venta_categoria_diaria
)
SELECT 'FALTA_EN_DESNORMALIZADA' AS tipo_desvio,
       e.fecha, e.categoria_id, e.total_vendido, a.total_vendido AS total_almacenado
FROM   esperado e
JOIN   almacenado a ON a.fecha = e.fecha AND a.categoria_id = e.categoria_id
WHERE  a.total_vendido IS DISTINCT FROM e.total_vendido;

-- Se repone desde la fuente de verdad (misma vía de escritura válida):
SELECT fn_recalculo_venta_categoria (:'dia'::date);
COMMIT;

-- Auditoría final: otra vez debe quedar vacía.
WITH esperado AS (
    SELECT   ped.fecha::date              AS fecha,
             pr.categoria_id              AS categoria_id,
             SUM (dp.cantidad * dp.precio_unitario) AS total_vendido,
             COUNT (*)                    AS cantidad_lineas
    FROM     detalle_pedido dp
    JOIN     pedido ped ON ped.id = dp.pedido_id AND NOT ped.eliminado
    JOIN     producto pr ON pr.id  = dp.producto_id
    GROUP BY 1, 2
),
almacenado AS (
    SELECT fecha, categoria_id, total_vendido, cantidad_lineas
    FROM   venta_categoria_diaria
)
SELECT COUNT (*) AS filas_de_desincronizacion
FROM   esperado e
FULL   JOIN almacenado a ON a.fecha = e.fecha AND a.categoria_id = e.categoria_id
WHERE  e.fecha IS NULL
   OR  a.fecha IS NULL
   OR  a.total_vendido   IS DISTINCT FROM e.total_vendido
   OR  a.cantidad_lineas IS DISTINCT FROM e.cantidad_lineas;

\echo '=== [8] REVERSIBILIDAD (script de reversa; no ejecutar en la corrida normal) ==='
-- La reversión es total y sin pérdida de información porque en el
-- esquema original NO se modificó ni una sola fila ni columna:
-- solo se agregaron objetos nuevos. Para volver:
--
--   DROP TABLE venta_categoria_diaria CASCADE;
--   DROP FUNCTION fn_recalculo_venta_categoria(DATE);
--   DROP FUNCTION fn_trg_venta_diaria_insert() CASCADE;
--   DROP FUNCTION fn_trg_venta_diaria_delete() CASCADE;
--   DROP FUNCTION fn_trg_venta_diaria_update() CASCADE;
--   DROP FUNCTION fn_trg_venta_diaria_pedido() CASCADE;
--
-- El reporte vuelve a resolverse con la consulta normalizada de [1].

\echo '--- Parte 2 finalizada ---'
