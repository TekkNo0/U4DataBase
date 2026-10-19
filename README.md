# U4 DataBase — FNBC y Desnormalización Controlada (Food Store)

Trabajo Práctico de la **Unidad 4** de Base de Datos II: llevar un esquema hasta la
**Forma Normal de Boyce-Codd (FNBC)** cuando una dependencia funcional lo exige, y
**desnormalizar de forma controlada** cuando una consulta real del sistema lo justifica
por rendimiento.

Motor: **PostgreSQL 17.x** · Base de trabajo: copia poblada de Food Store
(10 categorías, 50.000 productos, 200.000 pedidos, 600.000 líneas de `detalle_pedido`).

## Contenido

| Archivo | Descripción |
|---|---|
| `tp_fnbc_control_lote.sql` | **Parte 1.** Tablas maestras `lote`/`deposito`, esquema inicial `control_lote_almacen` + instancia de ejemplo, verificación de claves candidatas, descomposición sin pérdida, vista de compatibilidad y migración verificada. |
| `tp_desnormalizacion_top_categorias.sql` | **Parte 2.** Tabla resumen `venta_categoria_diaria`, mecanismo de sincronización (función de recálculo + disparadores), backfill, consulta optimizada con `EXPLAIN ANALYZE`, demostración de sincronización y script de auditoría. |
| `informe_TPU4_FNBC_Desnormalizacion.docx` / `.md` | Informe con las dependencias funcionales, claves candidatas, demostración de violación de FNBC, anomalías, justificación de la unión sin pérdida, capturas de `EXPLAIN ANALYZE` antes/después y justificación del patrón de desnormalización. |
| `evidencias/` | Salidas crudas de las corridas: `parte1_salida.txt`, `parte2_salida.txt`, `explain_antes.txt`, `explain_despues.txt`. |

## Cómo reproducir

```powershell
$env:PGPASSWORD='<password postgres>'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'

# 1. Crear una copia de la base poblada
& $psql -U postgres -h localhost -c "CREATE DATABASE foodstore_u4 TEMPLATE <base_poblada>;"

# 2. Parte 1 y Parte 2 (ambos scripts son idempotentes)
& $psql -U postgres -h localhost -d foodstore_u4 -X -v ON_ERROR_STOP=1 -f tp_fnbc_control_lote.sql
& $psql -U postgres -h localhost -d foodstore_u4 -X -v ON_ERROR_STOP=1 -f tp_desnormalizacion_top_categorias.sql
```

El día medido en la Parte 2 se parametriza en la primera línea del script:

```sql
\set dia '2025-04-24'
```

## Resultados principales

**Parte 1 — `control_lote_almacen` no cumple FNBC**

- FDs: `LoteID, DepositoID → ResponsableControlID` (FD1) y `ResponsableControlID → DepositoID` (FD2).
- Claves candidatas: `{LoteID, DepositoID}` y `{LoteID, ResponsableControlID}`. Los tres atributos son primos
  (por eso el esquema **sí** está en 3FN, pero **no** en FNBC).
- Viola FNBC por FD2: `ResponsableControlID` no es superclave. Descomposición sin pérdida en
  `control_lote_responsable` y `deposito_responsable`, con vista de compatibilidad y diferencias de
  verificación en ambos sentidos = 0 filas.

**Parte 2 — top 5 de categorías por monto vendido del día**

| | Antes (normalizada) | Después (desnormalizada) |
|---|---|---|
| Tiempo de ejecución | **50,3 ms** (49,7 – 62,3 ms) | **0,029 ms** (0,029 – 0,117 ms) |
| Nodo dominante | `Parallel Seq Scan` sobre `detalle_pedido` (600.000 filas) + 1.672 `Index Scan` a `producto` | `Index Scan` sobre `(fecha, total_vendido DESC)` (5 filas) |
| Buffers (hit/read) | 7.826 / 2.593 (≈ 83 MB) | 7 / 0 (≈ 56 KB) |

Ganancia ≈ **1.700×**. La auditoría de desincronización devuelve **0 filas**.
