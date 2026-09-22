# simple-stock-flow-infra

## 1. Qué es esto

El repositorio que **levanta el sistema completo**: base de datos, API y portal. Aquí viven el
`docker compose`, la red, los volúmenes y la configuración de entorno.

**De lo que no se ocupa:** del esquema de la base. No hay ni una línea de SQL en este repositorio.
Las tablas, los índices y las categorías de referencia los crea el propio servicio al arrancar,
con sus migraciones. Este repositorio entrega **un motor vacío**; el esquema es del servicio.

Para levantar el sistema hacen falta estas tres carpetas, **una al lado de la otra**: el compose
construye el servicio y el portal desde `../simple-stock-flow-api` y
`../simple-stock-flow-portal`, así que la disposición no es cosmética. Se clonan en el mismo
directorio y conservando su nombre:

```bash
mkdir simple-stock-flow && cd simple-stock-flow
git clone https://github.com/code-dev-projects/simple-stock-flow-infra.git
git clone https://github.com/code-dev-projects/simple-stock-flow-api.git
git clone https://github.com/code-dev-projects/simple-stock-flow-portal.git
```

```
simple-stock-flow/
├── simple-stock-flow-infra/     ← estás aquí: compose, .env.example y verify.sh
├── simple-stock-flow-api/       ← backend .NET 8
└── simple-stock-flow-portal/    ← front Angular 20
```

Los tres están publicados en la organización `code-dev-projects`, y **no hay submódulos a
propósito**: cada repositorio se clona y se lee solo. En esa misma organización hay tres más, y
ninguno hace falta para levantar nada de esto: `simple-stock-flow-tools` —el sembrador de los datos
de demostración y sus imágenes—, `simple-stock-flow-page` —la página pública— y
`simple-stock-flow-docs`, que es **privado** y guarda el material de trabajo del proyecto.

## 2. Cómo se levanta

Necesitas **solo Docker**. Ni .NET, ni Node, ni un cliente de base de datos.

```bash
cp .env.example .env
```

Abre `.env`. La plantilla trae **cuatro claves vacías**, y solo tres hacen falta para arrancar:
`POSTGRES_PASSWORD`, `JWT_SIGNING_KEY` (mínimo 32 caracteres) y `ADMIN_PASSWORD` —esta última es la
del primer administrador, y sin ella no hay forma de entrar al sistema—. La cuarta,
`DEMO_SELLER_PASSWORD`, solo la necesita el sembrador de `simple-stock-flow-tools`: déjala vacía si
no vas a sembrar los datos de demostración. Después:

**En producción**, solo el fichero base:

```bash
docker compose up -d --wait
```

El portal queda en **http://localhost:8080** (o el puerto que hayas puesto en `PORTAL_PORT`) y es el
**único** puerto publicado: la API y la base se quedan dentro de la red de Docker, y el portal hace
de proxy hacia la API.

**En desarrollo, añade siempre el solapamiento** `docker-compose.dev.yml`:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait
```

Publica además la base en `localhost:5432` y la API en **`localhost:5000`**. Los dos hacen falta:
`:5000` es la *base directa* que declara el contrato de API en su §1, es adonde apunta el
`proxy.conf.json` de `ng serve`, y sin él no se puede reproducir ni una sola de las sondas que el
contrato documenta contra ese puerto.

> **Cuidado al mezclar los dos arranques.** Levantar con el fichero base una pila que ya corría con
> el solapamiento **recrea el contenedor de la API y le quita el puerto publicado**, sin avisar. Si
> `:5000` deja de responder de golpe, es esto. Por eso `verify.sh` usa siempre los dos ficheros.

Para apagarlo conservando los datos:

```bash
docker compose down
```

Para apagarlo **borrando** los datos y los binarios subidos:

```bash
docker compose down -v
```

## 3. Dónde están los datos

Aquí no se siembra ningún dato: el `compose` levanta el motor vacío, la API y el portal, y el
esquema lo crea el servicio al arrancar. El catálogo de demostración —productos, imágenes y
ventas— lo carga después, por la API, una herramienta aparte llamada `simple-stock-flow-tools`:
es **opcional**, tiene sus propios requisitos y no hace falta para levantar nada de esto.

| Qué | Dónde |
|---|---|
| **Motor** | PostgreSQL 16, en el contenedor `db` |
| **Nombre de la base** | `simple_stock_flow` — variable `POSTGRES_DB` |
| **Usuario** | `simple_stock_flow` — variable `POSTGRES_USER` |
| **Contraseña** | La que pusiste en `POSTGRES_PASSWORD` dentro de tu `.env` |
| **Esquema** | `sales`. Las tablas **no** están en `public` |
| **Tablas** | `category`, `product`, `sale`, `sale_item`, `user` — **en singular**, por convención del proyecto |
| **Historial de migraciones** | `public."__EFMigrationsHistory"` — lo gestiona EF Core y es lo único que vive fuera de `sales` |
| **Imágenes subidas** | Volumen `media`, montado en `/var/lib/simple-stock-flow/media` dentro del contenedor `service` |

El servicio aplica sus migraciones al arrancar, y **su número cambia con cada tarea del backend**:
no lo copies aquí, míralo. Para ver cuáles se aplicaron de verdad:

```bash
docker compose exec db psql -U simple_stock_flow -d simple_stock_flow \
  -c 'select "MigrationId" from public."__EFMigrationsHistory" order by 1;'
```

**Por defecto el puerto de la base no se publica al host**: nada fuera del compose necesita hablar
con el motor. Para mirar los datos tienes dos caminos.

**Sin salir de Docker**, que no requiere instalar nada:

```bash
docker compose exec db psql -U simple_stock_flow -d simple_stock_flow -c "select * from sales.category;"
```

**Con tu cliente favorito** (DBeaver, pgAdmin, DataGrip), publicando el puerto:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

Y conectas a `localhost:5432`, base `simple_stock_flow`, usuario `simple_stock_flow`, con la
contraseña de tu `.env`.

**Los binarios** no están en la base: la base guarda solo una clave opaca. Para verlos:

```bash
docker compose exec service ls -la /var/lib/simple-stock-flow/media
```

## 4. Configuración

Todo vive en `.env`, y `.env.example` declara **todas las claves obligatorias** sin un solo valor
real de secreto: cuatro de ellas vienen vacías —las tres del arranque y la del sembrador (§2)—.

| Variable | Qué hace | Valor por defecto |
|---|---|---|
| `POSTGRES_DB` · `POSTGRES_USER` · `POSTGRES_PASSWORD` | Base, usuario y contraseña del motor | Los dos primeros sí; la contraseña **no** |
| `JWT_SIGNING_KEY` | Firma de los tokens. Mínimo 32 caracteres | **Ninguno, a propósito.** Sin ella la API debe negarse a arrancar en vez de firmar con relleno |
| `ADMIN_USERNAME` · `ADMIN_PASSWORD` | Primer administrador. Se pasan al servicio como `Bootstrap__AdminUsername` y `Bootstrap__AdminPassword`, y **el servicio los lee al arrancar**: crea con ellos al administrador la primera vez (§6). Sin contraseña no se crea, y no hay forma de entrar al sistema | Usuario sí (`admin`), contraseña **no** |
| `PORTAL_PORT` | El único puerto publicado al host en producción | `8080` |
| `SWAGGER_ENABLED` | Monta o retira la documentación ejecutable. No cambia nada más: ningún endpoint aparece ni desaparece con ella | `true` |
| `DEMO_SELLER_PASSWORD` | Contraseña del vendedor de demostración que crea el sembrador de `simple-stock-flow-tools`. **No hace falta para arrancar**: sin ella el sembrador se detiene y lo dice | **Ninguno**, y viene vacía |
| `POSTGRES_PORT` | Puerto del host para la base. **Solo se usa con el solapamiento de desarrollo** (`docker-compose.dev.yml`); sin él la base no se publica. Opcional, y por eso no aparece en `.env.example` | `5432` |
| `SERVICE_PORT` | Puerto del host para la API, la *base directa* del contrato. **Solo con el solapamiento de desarrollo.** Opcional, y por eso no aparece en `.env.example` | `5000` |

`.env.example`, el `docker-compose` y `verify.sh` están **en inglés**, como el resto del código del
proyecto. Este README está en español porque lo lee una persona.

## 5. Cómo se prueba

```bash
./verify.sh
```

Ejecuta las comprobaciones de aceptación del repositorio —termina imprimiendo cuántas pasaron y
cuántas fallaron, y ese número es el que vale— agrupadas en secciones:
que la configuración esté declarada y sin secretos dentro, que los tres servicios queden sanos, que
el portal responda, que la API conteste a través del portal **exigiendo token**, que el esquema se
haya creado solo con sus categorías, que **los datos sobrevivan a un reinicio**, que un secreto
ausente se note y —§6— que **lo desplegado sea lo que dice el código fuente**.

La §6 es la más reciente y nació de un fallo real: la imagen del portal se había construido **dos
horas antes** que su código, así que tres correcciones ya escritas no estaban desplegadas, y nada lo
detectaba —`up -d --wait` adopta la imagen que ya existe y nunca reconstruye—. Comprueba, por
contenido y nunca por identificador de imagen (una reconstrucción cacheada acuña un id nuevo igual):

- que el **`index.html` servido** por el puerto 8080 sea el que produce el código de hoy;
- que el **`nginx.conf` que corre** el contenedor sea el que declara el repositorio del portal —un
  cambio solo en el proxy no mueve el `index.html`, y sin esto las tres comprobaciones siguientes
  estarían midiendo un contenedor viejo;
- que `/media/*.jpg`, `*.png` y `*.webp` **lleguen a la API** y no los conteste nginx con su propia
  página de 404 (defecto A-6);
- que una subida de **2 MB cruce nginx**, para que el 422 de los 5 MB que decide el contrato sea
  alcanzable en vez de un 413 en HTML;
- que la API responda en **`:5000`**, la base directa del contrato.

Deja el stack levantado; con `./verify.sh --down` lo apaga al acabar. **Aquí no se publica cuántas
comprobaciones son**: la cifra la imprime el guion al terminar, y una escrita en esta línea
envejecería sin que nadie se enterara.

Dos de sus secciones, la §8 y la §9, no auditan el sistema sino los **documentos del proyecto**, y
esos viven en `simple-stock-flow-docs`, que es un repositorio **privado**. Si has clonado solo los
tres repositorios públicos, esas comprobaciones fallan diciendo qué archivo les falta, y el guion
sale con código distinto de cero. Es lo esperado y no significa que el sistema esté mal: todo lo
que audita el sistema está en las secciones anteriores.

Se escribió **antes** que el `docker-compose`, y al principio fallaba en todas. La §6 se escribió
igual: primero la comprobación, se la vio fallar contra la imagen vieja, y después se reconstruyó.

**Levanta con los dos ficheros de compose** (§2) y **reconstruye la imagen del portal**, así que
tarda más que antes. Es el precio de que la §6 pueda decir la verdad.

No comprueba que el sistema se pueda usar de punta a punta, y no debe: eso depende del servicio, no
de este repositorio.

## 6. Qué falta

**Nada.** Lo que este apartado llegó a declarar pendiente —publicar los repositorios, el arranque
del administrador y la autenticación— está hecho y comprobado contra la pila levantada.

Los seis repositorios viven en `code-dev-projects` y **ninguno es submódulo de otro**, a propósito:
cada uno se clona y se lee solo. Los tres que hacen falta para levantar el sistema están en §1.

Para saber el estado ejecute `./verify.sh`, que es lo único que mira la frontera entre el código y
su empaquetado, donde no llegan ni el compilador ni los tests.

## Licencia

MIT. Copyright (c) 2026 Jesus Ariel Gonzalez Bonilla. El texto completo está en
[`LICENSE`](LICENSE): puede usarse, copiarse, modificarse y distribuirse libremente, con la única
condición de conservar el aviso de copyright.
