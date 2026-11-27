# KeySwitch ES — cambio automático de teclado EN/ES para macOS

Aplicación de barra de menús para teclados inglés y español. Reconoce palabras al pulsar espacio, cambia el teclado para el siguiente texto y corrige caracteres que salen distintos entre ambos teclados. Funciona sin servicios de IA ni red.

## Descargar

[KeySwitch ES 0.3.9 para macOS](https://github.com/dimyan-l/KeySwitch/releases/tag/es-v0.3.9)

Descomprime el ZIP y mueve KeySwitchES.app a Aplicaciones. Activa un teclado inglés y uno español. Abre los ajustes de KeySwitch ES, concede Accesibilidad y Monitorización de entrada y vuelve a abrir la aplicación si macOS lo solicita.

## Cómo funciona

- Tras `hola`, `gracias` o `casa` escritos con el teclado inglés, cambia al español. Tras `hello`, `thanks` o `the` con el teclado español, cambia al inglés.
- Las letras A–Z están en las mismas teclas en los dos diseños QWERTY. Por eso, cambiar de idioma normalmente **no reescribe** la palabra: cambia el teclado para la puntuación, `ñ` y los acentos que escribas después.
- Si una tecla sí produjo otro carácter, por ejemplo `ni;o` con teclado inglés en vez de `niño` con teclado español, puede reescribir la palabra.
- Activa «Corregir erratas» en Ajustes → Correcciones para corregir casos claros como `gracais` → `gracias` y `recieve` → `receive` al pulsar espacio.
- Si un término es frecuente en ambos idiomas, conserva el teclado actual. Los nombres propios y las palabras desconocidas se pueden añadir a `my_en.txt` o `my_es.txt`.
- Los acentos compuestos con teclas muertas se conservan como se escribieron; la conversión automática de sus secuencias depende del diseño de teclado instalado.

## Controles

| Acción | Control |
|---|---|
| Deshacer la última corrección o corregir la palabra actual | Pulsar y soltar el ⌥ derecho |
| Convertir texto seleccionado con el otro teclado | ⌃⌥R |
| Corregir una palabra ya escrita o cambiar mayúsculas | Seleccionar una palabra con el ratón o Mayús+flecha y elegir una opción en la ventana flotante |
| Historial del portapapeles (30 textos, frases fijadas) | ⌃⌥V |
| Cambiar o pausar la corrección en una aplicación | Menú → «Modo en…» |
| Añadir términos propios | Ajustes → Diccionarios → Mis palabras |
| Añadir o quitar excepciones para teclado y erratas | Ajustes → Diccionarios → Excepciones |

Los terminales, IDE y gestores de contraseñas están excluidos por defecto. El historial del portapapeles permanece en memoria; los textos fijados se guardan en `~/Library/Application Support/KeySwitchES/`.
No hay ventanas de sugerencias: seleccionar una palabra no muestra nada y ⌥ derecho aplica directamente la mejor opción (otra pulsación la deshace).

El **modo prudente** está activado por defecto: una sugerencia basada solo en estadísticas se indica en naranja y se aplica únicamente con ⌥ derecho. Se protegen las direcciones, los identificadores con `_`, palabras con números y tokens con puntos internos. Si cambias de teclado a mitad de palabra, KeySwitch ES espera el siguiente espacio para empezar a comprobar de nuevo. Tab e Intro dejan que la aplicación de destino reciba la tecla. La reescritura automática se limita a 24 caracteres.

La instalación nueva incluye excepciones inglesas importadas de KeySwitch 0.3.2. No había excepciones españolas en esa base; puedes añadirlas desde Ajustes → Diccionarios. Las erratas inglesas y españolas se corrigen con los diccionarios locales. Si borras una excepción, no reaparece al reiniciar.

## Apariencia

KeySwitch ES comparte los ajustes en tonos pastel y el indicador de barra de menús de KeySwitch 0.3.8. El indicador muestra EN o ES y Ⅱ durante una pausa. Las animaciones respetan la opción Reducir movimiento de macOS.

## Compilar e instalar

Requiere macOS 13 o posterior y Swift Command Line Tools. Activa los teclados de inglés y español en Ajustes del sistema. Desde esta carpeta:

```bash
swift build -c release
.build/release/KeySwitchES --selftest
./build_app.sh
```

Concede **Accesibilidad** y **Monitorización de entrada** a KeySwitchES en Ajustes del sistema. Desactiva otros correctores globales de teclado para evitar correcciones simultáneas.

Puedes comprobar los permisos de la copia instalada sin activar la captura de teclas: `/Applications/KeySwitchES.app/Contents/MacOS/KeySwitchES --diagnose-permissions`. Si ambos aparecen concedidos, consulta el mensaje del menú antes de cambiar los permisos de nuevo.

`/Applications/KeySwitchES.app/Contents/MacOS/KeySwitchES --diagnose-data` muestra el número de palabras aprendidas y excepciones sin activar la captura de teclas.

`./build_app.sh` sin `--install` crea `build/KeySwitchES.app` sin tocar `/Applications`. La instalación no abre la aplicación automáticamente; ábrela tú después de comprobar los permisos.

Las compilaciones sin un certificado de firma estable usan una firma temporal; macOS puede volver a pedir los permisos después de actualizar. El certificado local de KeySwitch RU no se usa para KeySwitch ES. Para instalar, firma la aplicación con tu propio certificado y ejecuta `KEYSWITCH_ES_CODESIGN_IDENTITY="Nombre del certificado" ./build_app.sh --install`. Sin certificado, o si ya existe `KeySwitchES 2.app` en Aplicaciones, el script detiene la instalación antes de reemplazar nada.

## Datos y licencias

`es.tsv` contiene 49 525 palabras filtradas de [FrequencyWords, OpenSubtitles 2018, español](https://github.com/hermitdave/FrequencyWords/blob/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/es/es_50k.txt). El script de conversión está en `tools/build_es_dict.py`. La lista y su derivado se distribuyen con [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). `en.tsv` y `custom_en.txt` proceden del proyecto KeySwitch RU/EN, con atribuciones en su README. Consulta `DICTIONARY_LICENSE.md` antes de redistribuir la aplicación.

## Limitaciones

La clasificación se realiza al finalizar una palabra. La selección de texto presupone que el teclado activo es el diseño con el que se escribió. El comportamiento de caracteres especiales varía entre Español, Español ISO, Español Latinoamericano y diseños de terceros; KeySwitch ES usa las tablas reales de los teclados activos de macOS.

Puedes pausar la captura desde el menú. Tras varios tiempos de espera seguidos, usa «Reanudar KeySwitch ES» para volver a activarla. Para desactivar el inicio automático sin abrir la aplicación: `KeySwitchES.app/Contents/MacOS/KeySwitchES --disable-login`.

### Ajustes y diagnóstico

«Ajustes…» abre una ventana con correcciones, diccionarios, aplicaciones excluidas y atajos. Los diccionarios permiten buscar, añadir, eliminar y deshacer el último cambio. Los últimos 50 cambios se conservan solo durante la sesión. El indicador compacto muestra Ⅱ cuando está en pausa.

Para recibir contadores y tiempos sin registrar el texto ni las pulsaciones, abre KeySwitch ES con `--diagnostics`. El argumento `--backspace-undo` habilita el deshacer inmediato con Retroceso cuando Accesibilidad puede verificar el texto junto al cursor. Cierra KeySwitch ES antes de abrirla con esos argumentos.

```bash
open -a /Applications/KeySwitchES.app --args --diagnostics --backspace-undo
log stream --predicate 'subsystem == "com.levantovsky.keyswitches"'
```

Si tienes instalada la edición RU/EN, pausa una edición antes de usar la otra.
