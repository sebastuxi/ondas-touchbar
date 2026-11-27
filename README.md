# Ondas

Barra de Spotify para la Touch Bar: foto del disco, canción y grupo con los colores del disco,
y un espectro de barras que se mueve con la música y también sirve de barra de progreso.

Diseño: https://claude.ai/artifact/QrwcBNo6wRPDZCe6WSri2N#artboard-Ondas-Barras

## Instalar

Hace falta una Mac con Touch Bar, macOS 14.2 o posterior y Xcode (o solo las herramientas de
línea de comandos: `xcode-select --install`).

```sh
git clone https://github.com/sebastuxi/ondas-touchbar.git
cd ondas-touchbar
./scripts/install.sh            # compila, copia a ~/Applications/Ondas.app y la abre
```

También sirve bajar el ZIP desde GitHub (Code → Download ZIP), descomprimirlo y correr
`./scripts/install.sh` dentro de la carpeta. La primera vez, macOS pide los permisos de abajo.
«Me gusta» se conecta aparte, con tu propia app de Spotify (ver **Me gusta** en Uso).

`./scripts/build-app.sh` solo compila (deja la app en `build/Ondas.app`).

Para que macOS recuerde los permisos aunque vuelvas a compilar, firma con tu certificado de desarrollo:

```sh
security find-identity -v -p codesigning            # copia el código largo de tu certificado
ONDAS_SIGN_IDENTITY=<código> ./scripts/install.sh
```

## Permisos (se piden una vez)

- **Automatización → Spotify:** leer qué suena, pausar, cambiar de canción y adelantar.
- **Grabación de audio del sistema:** escuchar el sonido de Spotify para mover las barras.
  No se graba ni se guarda nada. Sin este permiso, las barras se mueven con un ritmo simulado.
- **Ubicación:** para el clima del reposo. Se redondea a ~1 km y solo se envía a
  [Open-Meteo](https://open-meteo.com) (gratis, sin cuenta). Sin este permiso, el reposo muestra la hora
  y la música, sin clima (menú ≋ → «Dar permiso de ubicación para el clima…»).
- **Monitorización de entrada:** para las ondas al escribir. Ondas solo usa la posición de cada tecla;
  no lee, guarda ni envía lo que escribes.

## Uso

- La barra se abre sola cuando Spotify está al frente y se recoge al cambiar de app.
- La X cuadrada de la izquierda (va en el sitio de Esc): con música pasa a la pantalla de reposo; en reposo
  cierra Ondas. Se vuelve a abrir con el botón de Ondas en la Control Strip, con el menú ≋ o al darle play.
- **Desliza la canción** con el dedo (sobre la foto o el nombre): a la izquierda pasa a la siguiente y a la
  derecha vuelve a la anterior. Al llegar al punto en que cambia aparece la flecha entera; si sueltas antes,
  la canción vuelve a su sitio.
- **Bichito bailando:** hace de cabezal sobre la barra de progreso e improvisa con la música. Tiene 20 pasos
  (rebote, saltitos, salto grande, paso al lado, disco, techo, olas, palmas, cabeceo, twist, giro, robot, meneo,
  patadas, hombros, vaivén, triste, pose, apuntar, marcha) y en cada compás elige el siguiente según lo que suena:
  energía (bombos por segundo, brillo, qué tan marcado está el pulso), estribillo o estrofa, graves o agudos y ánimo
  (tono mayor o menor). Si la canción explota, salta o gira; si se calma, baja el ritmo; con canciones tristes se pone
  triste (cejas de pena, antenas caídas y alguna lagrimita). Además rebota con cada bombo y mueve los brazos con los
  platillos. Toma el color de la portada y cada canción tiene su propia coreografía. En pausa se sienta y mira el play.
  Tócalo y se ríe; arrástralo y te lo llevas por la canción. Se quita en el menú ≋ → «Bichito bailando».
  Necesita que la música suene en la Mac: si Spotify suena en otro dispositivo, no hay nada que escuchar y baila
  con un pulso tranquilo. (Spotify ya no da a las apps nuevas el tempo ni el ánimo de cada canción, ni los géneros.)
- **Reposo** (con la X, sin música o tras 1 min en pausa): hora y fecha (toca para abrir Calendario),
  clima (toca para abrir Tiempo), «Sonando ahora» o «Seguir escuchando» y batería.
- **Al enchufar el cargador**, una ola verde llena la barra hasta tu % de batería y vuelve sola a lo de antes
  (unos 2.5 s). Si tocas la barra, se quita al instante.
- Toda la barra se ilumina con los colores de la portada siguiendo la canción: más brillo en lo fuerte,
  menos en lo suave y un destello en los golpes (como mucho 3 por segundo, umbral seguro para la vista).
  Si no llega audio real, el brillo queda quieto.
- **Ondas al escribir:** con cada tecla, la luz del teclado sube suave y vuelve despacio a tu brillo, y en la
  Touch Bar sale una onda de color justo encima de la tecla que pulsaste. Necesita el permiso
  «Monitorización de entrada»; Ondas solo usa la posición de la tecla (no lee, guarda ni envía lo que escribes).
- **Me gusta:** el corazón junto al nombre guarda o quita la canción de tus «Me gusta». La primera vez
  pide conectar tu cuenta (menú ≋ → «Conectar Me gusta de Spotify…»): crea una app en
  https://developer.spotify.com/dashboard con la Redirect URI `http://127.0.0.1:8721/callback`,
  marca «Web API» y pega su Client ID. El token queda en el Llavero.
- **Se abre al encender la Mac** (se puede quitar en el menú ≋).
- Ondas ocupa toda la Touch Bar y trae sus propias teclas de **brillo** y **volumen** (se rellenan según el nivel).
  Al tocarlas, la barra se vuelve un deslizador grande; arrastra para ajustar. En el de volumen, el altavoz
  de la izquierda activa o quita el **silencio**. Vuelve sola a la canción a los 2.5 s.
- Toca o arrastra sobre las barras para moverte por la canción.
- Toca la foto o el nombre para abrir Spotify.
- Menú ≋ en la barra de menús: mostrar la barra, abrir sola con Spotify, barras con la música real, salir.

## Opcional: quitar Siri de la Control Strip

```sh
defaults write com.apple.controlstrip MiniCustomized -array com.apple.system.brightness com.apple.system.volume com.apple.system.mute
killall ControlStrip
```

Para recuperarlo: `defaults delete com.apple.controlstrip MiniCustomized && killall ControlStrip`.

## Nota técnica

Ondas usa la API privada de la Touch Bar (`presentSystemModalTouchBar`, la misma que usan MTMR y Pock)
para mostrarse encima de cualquier app. Apple podría cambiarla en futuras versiones de macOS.

Datos del clima: [Open-Meteo.com](https://open-meteo.com) (licencia CC BY 4.0).

Para revisar el diseño sin tocar la barra (capturas con `screencapture -b`), ábrela con una vista previa:

```sh
open ~/Applications/Ondas.app --args -OndasPreview idle,weather   # también: swipe, charging
open ~/Applications/Ondas.app --args -OndasPreview fast           # bichito: dance, calm, bass, fast, bright, sad, moves, sit, carry
```

Con `weather` el clima es de ejemplo (no se pide el real). Para volver a lo normal, ciérrala y ábrela sin `--args`.
