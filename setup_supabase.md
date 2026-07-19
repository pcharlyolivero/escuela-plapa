# Escuela PLAPA · Setup del Supabase

Guía paso a paso para dejar el backend funcionando. Tiempo estimado: **15–20 minutos**.

---

## 1. Crear el proyecto Supabase

1. Andá a https://supabase.com y creá cuenta si no la tenés.
2. Botón **"New project"**.
3. Datos:
   - **Name**: `escuela-plapa`
   - **Database password**: generá una y guardala en un lugar seguro (la vas a necesitar solo si querés conectarte por SQL directo desde afuera).
   - **Region**: `São Paulo` o `us-east-1` (los más cercanos a Latinoamérica).
   - **Plan**: Free alcanza para arrancar.
4. Esperá 2–3 minutos a que se aprovisione.

---

## 2. Configurar Auth (Email/Password)

1. Menú lateral → **Authentication** → **Providers**.
2. **Email** debería estar activo por defecto. Verificalo.
3. **Importante para desarrollo inicial**: en **Authentication → Providers → Email** desactivá "Confirm email" para poder testear sin verificación de correo. Cuando esté en producción, volvelo a activar.
4. Menú lateral → **Authentication** → **URL Configuration**:
   - **Site URL**: la URL final donde va a vivir la Escuela (ej. `https://escuela-plapa.pages.dev` o el dominio propio). Para probar local: `http://localhost:8000` o similar.
   - **Redirect URLs**: agregá `https://tu-dominio/login.html` (para la recuperación de contraseña).

---

## 3. Pegar el schema

1. Menú lateral → **SQL Editor** → **+ New query**.
2. Abrí el archivo `escuela_plapa_schema.sql` que te preparé.
3. Copiá **todo** el contenido y pegalo en el editor.
4. Botón **Run** (arriba a la derecha). Debería tardar 5–10 segundos.
5. Si sale verde: listo. Si sale rojo, mandame el error y lo miramos.

Lo que se creó:
- Tablas: `perfiles`, `foro_comentarios`, `foro_reacciones`, `evaluaciones_itinerario`
- Triggers: crear perfil al signup, autopoblar autor en comentarios, registrar moderación, actualizar `updated_at`
- Políticas RLS: quién puede leer/escribir qué en cada tabla
- Funciones RPC: `comentarios_para_itinerario`, `toggle_reaccion`

---

## 4. Copiar las credenciales al frontend

1. Menú lateral → **Project Settings** (engranaje abajo a la izquierda) → **API**.
2. Copiá dos valores:
   - **Project URL** — algo como `https://abcdefghij.supabase.co`
   - **Project API key** → **`anon` `public`** (NO uses la `service_role` — esa es secreta)
3. Abrí `login.html` y `itinerario_1_llaga_v4.html`. En cada uno, buscá al principio del `<script>` estas dos líneas:

```javascript
var SUPABASE_URL = 'https://TU-PROYECTO.supabase.co';   // TODO: config
var SUPABASE_ANON_KEY = 'TU_ANON_KEY';                   // TODO: config
```

Reemplazá los valores. **Son 4 reemplazos en total** (2 líneas × 2 archivos).

> ⚠️ La `anon key` es pública por diseño — puede ir en HTML client-side sin problema. Lo que la protege es la RLS que definimos en el SQL. Nunca pongas la `service_role` en el frontend.

---

## 5. Crear tu cuenta y hacerte moderador

1. Abrí `login.html` en el navegador.
2. Pestaña **Inscribirme**. Registrate con tu email real.
3. Volvé al Supabase → **SQL Editor** → **+ New query** y ejecutá:

```sql
update public.perfiles
set es_moderador = true
where id = (select id from auth.users where email = 'tu-email@ejemplo.com');
```

Reemplazá el email por el tuyo. Ahora tu cuenta puede aprobar comentarios y ver evaluaciones compartidas.

Para dar moderación a otros del equipo PLAPA, repetí con sus emails después de que se registren.

---

## 6. Probar el flujo

1. En una ventana normal, entrá a `catalogo_30_itinerarios_plapa_corregido.html` → click en Itinerario 1.
2. Como no hay sesión (o si te deslogueás desde la consola con `localStorage.clear()`), te redirige a `login.html?next=itinerario_1_llaga_v4.html`.
3. Ingresá con tu cuenta → vuelve al itinerario.
4. Recorré los tabs. En el **Muro del camino**, dejá un comentario de prueba.
5. Volvé a Supabase → **Table Editor** → **foro_comentarios**. Vas a ver tu comentario con `estado = 'pendiente'`.
6. Cambialo a `'publicado'` (doble click en la celda) o corré:

```sql
update public.foro_comentarios set estado = 'publicado' where estado = 'pendiente';
```

7. Recargá la página del itinerario → tu comentario aparece en el muro.

---

## 7. Panel de moderación (próximo paso)

Los comentarios llegan como `pendiente`. Hoy los aprobás manualmente en el Table Editor de Supabase, que funciona pero es incómodo.

Cuando quieras, te armo un panel simple (`moderacion.html`) con lista de pendientes + botones aprobar/rechazar + vista de evaluaciones compartidas. Solo lo pueden abrir quienes tengan `es_moderador = true`.

---

## Verificación rápida — ¿todo salió bien?

Corré esta consulta en el SQL Editor para chequear que todo esté en su lugar:

```sql
select
  (select count(*) from information_schema.tables where table_schema = 'public'
   and table_name in ('perfiles','foro_comentarios','foro_reacciones','evaluaciones_itinerario')) as tablas,
  (select count(*) from pg_proc where proname in ('comentarios_para_itinerario','toggle_reaccion','crear_perfil_desde_signup')) as funciones,
  (select count(*) from pg_policies where schemaname = 'public') as politicas_rls;
```

Deberías ver:
- `tablas = 4`
- `funciones = 3` (o más)
- `politicas_rls = 13` o similar

---

## Estructura de archivos del proyecto

```
escuela-plapa/
├── index.html                            (existente)
├── catalogo_30_itinerarios_plapa...html  (existente)
├── login.html                            ← NUEVO
├── itinerario_1_llaga_v4.html            ← ACTUALIZADO (v3 → v4)
├── itinerario_2_..._v2.html              (aún sin muro/eval)
├── itinerario_3_..._v2.html              (aún sin muro/eval)
├── ...
└── escuela_plapa_schema.sql              ← NUEVO (para Supabase)
```

Cuando esto funcione, replicamos el patrón (guard de sesión + 2 tabs) a los otros 4 itinerarios ya escritos. Se puede automatizar con un script.

---

## Costos

Free tier de Supabase incluye:
- 500 MB de base de datos
- 50.000 usuarios mensuales activos
- 2 GB de transferencia

Alcanza cómodamente para arrancar los primeros meses. Cuando la Escuela crezca, el plan Pro son USD 25/mes.
