-- ============================================================
-- TP Unidad 4 - Parte 1
-- FNBC en control_lote_almacen (extensión mayorista Food Store)
--
-- Entregable: tp_fnbc_control_lote.sql
-- Motor:      PostgreSQL 17.x
-- Base:       foodstore_u4 (copia de la base Food Store poblada)
--
-- Contenido:
--   0) Tablas maestras del dominio mayorista (lote, deposito)
--   1) Esquema inicial control_lote_almacen + instancia de ejemplo
--   2) Verificación de claves candidatas sobre la instancia
--   3) Descomposición sin pérdida (algoritmo: extraer el FD
--      no-cumple-FNBC a una tabla con su determinante como PK)
--   4) Vista de compatibilidad (unión natural)
--   5) Migración de datos + verificación de equivalencia
--   6) Eliminación de la relación que violaba FNBC
--
-- El script es idempotente: puede ejecutarse tantas veces como
-- se quiera sobre la misma base.
-- ============================================================

\echo '--- [0] Tablas maestras del dominio mayorista ---'

-- En el enunciado se asumen existentes (análogo a 'sucursal' en
-- AsignacionEntrega). En Food Store todavía no existen, así que
-- se crean aquí. Se usan ids explícitos para reproducir la
-- instancia de ejemplo del enunciado (lotes 501-503, depósitos 30-31).
CREATE TABLE IF NOT EXISTS lote (
    id                    BIGINT PRIMARY KEY,
    proveedor             TEXT    NOT NULL,
    producto_descripcion  TEXT    NOT NULL,
    fecha_recepcion       DATE    NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT ck_lote_id_positivo CHECK (id > 0)
);

CREATE TABLE IF NOT EXISTS deposito (
    id      BIGINT PRIMARY KEY,
    nombre  TEXT  NOT NULL,
    CONSTRAINT ck_deposito_id_positivo CHECK (id > 0)
);

INSERT INTO lote (id, proveedor, producto_descripcion, fecha_recepcion) VALUES
    (501, 'Distribuidora Norte',  'Harina 000 - 25 kg',            CURRENT_DATE),
    (502, 'Distribuidora Norte',  'Harina 000 - 25 kg',            CURRENT_DATE),
    (503, 'Lácteos del Sur',      'Queso mozzarella - 15 kg',      CURRENT_DATE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO deposito (id, nombre) VALUES
    (30, 'Depósito Central'),
    (31, 'Depósito Norte')
ON CONFLICT (id) DO NOTHING;

\echo '--- [1] Esquema inicial (viola FNBC) ---'

DROP VIEW  IF EXISTS control_lote_almacen_compat CASCADE;
DROP TABLE IF EXISTS control_lote_almacen            CASCADE;
DROP TABLE IF EXISTS control_lote_responsable        CASCADE;
DROP TABLE IF EXISTS deposito_responsable            CASCADE;

CREATE TABLE control_lote_almacen (
    lote_id                 BIGINT NOT NULL REFERENCES lote (id),
    deposito_id             BIGINT NOT NULL REFERENCES deposito (id),
    responsable_control_id  BIGINT NOT NULL REFERENCES usuario (id),
    PRIMARY KEY (lote_id, deposito_id)
);

-- Instancia de ejemplo del enunciado. Los responsables 801 y 802
-- son usuarios existentes de Food Store.
INSERT INTO control_lote_almacen (lote_id, deposito_id, responsable_control_id) VALUES
    (501, 30, 801),
    (502, 30, 801),
    (503, 31, 802);

\echo '--- [2] Verificación sobre la instancia: ¿(LoteID, ResponsableControlID) es clave? ---'

-- Claves candidatas teóricas:
--   K1 = (LoteID, DepositoID)            -> es la PK, por definición clave.
--   K2 = (LoteID, ResponsableControlID)  -> clausura: ResponsableControlID ->
--        DepositoID (FD2), y luego (LoteID, DepositoID) -> ResponsableControlID (FD1).
-- Verificación empírica de K2: la consulta debe devolver 0 filas duplicadas.
SELECT lote_id, responsable_control_id, COUNT(*) AS repeticiones
FROM   control_lote_almacen
GROUP  BY lote_id, responsable_control_id
HAVING COUNT(*) > 1;

-- Redundancia observable de la FD (LoteID, DepositoID) -> ResponsableControlID:
-- es la PK, no puede haber duplicados en su determinante.
SELECT lote_id, deposito_id, COUNT(*) AS repeticiones
FROM   control_lote_almacen
GROUP  BY lote_id, deposito_id
HAVING COUNT(*) > 1;

-- Exceso de redundancia de la FD ResponsableControlID -> DepositoID:
-- el par (801, 30) está almacenado dos veces porque la tabla no tiene
-- una clave que lo cubra. Esta consulta devuelve 1 fila:
SELECT responsable_control_id, COUNT(DISTINCT deposito_id) depositos_distintos,
       COUNT(*) filas_almacenadas
FROM   control_lote_almacen
GROUP  BY responsable_control_id
HAVING COUNT(*) > 1;

\echo '--- [3] Descomposición sin pérdida ---'

-- Descomposición:  R1(LoteID, ResponsableControlID)
--                  R2(DepositoID, ResponsableControlID)
-- Se extrae el FD no-cumple-FNBC  ResponsableControlID -> DepositoID
-- a R2, cuya clave primaria es precisamente su determinante.
CREATE TABLE control_lote_responsable (
    lote_id                 BIGINT NOT NULL REFERENCES lote (id),
    responsable_control_id  BIGINT NOT NULL REFERENCES usuario (id),
    PRIMARY KEY (lote_id, responsable_control_id)
);

CREATE TABLE deposito_responsable (
    responsable_control_id  BIGINT PRIMARY KEY REFERENCES usuario (id),
    deposito_id             BIGINT NOT NULL REFERENCES deposito (id)
);

\echo '--- [4] Vista de compatibilidad (unión natural sobre ResponsableControlID) ---'

CREATE VIEW control_lote_almacen_compat AS
SELECT lr.lote_id,
       dr.deposito_id,
       lr.responsable_control_id
FROM   control_lote_responsable lr
JOIN   deposito_responsable     dr USING (responsable_control_id);

\echo '--- [5] Migración de la instancia de ejemplo ---'

-- R1: cada lote controlado, con su responsable.
INSERT INTO control_lote_responsable (lote_id, responsable_control_id)
SELECT DISTINCT lote_id, responsable_control_id
FROM   control_lote_almacen;

-- R2: cada responsable, con el depósito al que pertenece (una fila por
-- responsable gracias a la PK sobre ResponsableControlID: eso es
-- exactamente lo que la tabla original no podía garantizar).
INSERT INTO deposito_responsable (responsable_control_id, deposito_id)
SELECT DISTINCT responsable_control_id, deposito_id
FROM   control_lote_almacen;

\echo '--- [5a] Verificación de equivalencia (ambas diferencias deben quedar vacías) ---'

-- (a) filas de la vista que no están en la relación original:
SELECT 'vista_menos_original' AS chequeo, *
FROM (
    SELECT * FROM control_lote_almacen_compat
    EXCEPT
    SELECT * FROM control_lote_almacen
) d;

-- (b) filas de la relación original que no están en la vista:
SELECT 'original_menos_vista' AS chequeo, *
FROM (
    SELECT * FROM control_lote_almacen
    EXCEPT
    SELECT * FROM control_lote_almacen_compat
) d;

-- (c) contenido final de las tablas descompuestas y de la vista:
SELECT * FROM control_lote_responsable ORDER BY lote_id;
SELECT * FROM deposito_responsable     ORDER BY responsable_control_id;
SELECT * FROM control_lote_almacen_compat ORDER BY lote_id;

\echo '--- [6] Eliminación de la relación que violaba FNBC ---'

-- Una vez migrado y verificado, la tabla original se elimina: conservarla
-- mantendría viva la redundancia y las anomalías (y la posibilidad de que
-- alguien escriba en ella y desincronice las descompuestas).
DROP TABLE control_lote_almacen CASCADE;

\echo '--- Parte 1 finalizada ---'
