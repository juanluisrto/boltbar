# Mejoras pendientes de experiencia de uso en Boltbar

Fecha: 19 de octubre de 2026.

Dos mejoras identificadas durante el uso de Boltbar: hacer más legibles los enlaces y las citas, y permitir preparar mensajes mientras el modelo responde. Las secciones siguientes recogen la propuesta original; la última, [Decisiones e implementación](#decisiones-e-implementación), describe lo que se implementó y en qué se aparta de la propuesta.

## Enlaces y citas dentro de las respuestas

### Problema observado

Las citas numéricas se distinguen poco del texto normal y pueden quedar pegadas al fragmento siguiente, como `1If` o `2Max`. Esto dificulta reconocer que son enlaces y perjudica la lectura.

En el flujo de citas de Anthropic se inserta un espacio antes del enlace, pero no se garantiza separación con el texto que llega después durante el streaming.

### Propuesta

- Representar las citas numéricas con una pequeña pastilla, por ejemplo `↗ 1`, con fondo sutil, color de acento y separación a ambos lados.
- Mostrar el dominio de la fuente al pasar el ratón y abrir el enlace al pulsar.
- Mantener los enlaces con texto descriptivo integrados en la frase, con color de acento y subrayado fino.
- Adaptar el estilo al tema seleccionado y permitir reconocer los enlaces sin depender únicamente del color.
- Corregir la separación durante el streaming sin alterar la puntuación ni el formato del texto circundante.

### Criterios de aceptación

- Una cita nunca queda pegada a la palabra siguiente.
- Las citas y los enlaces se reconocen como elementos pulsables en temas claros y oscuros.
- Las citas consecutivas conservan una separación clara.
- El estilo funciona dentro de párrafos y listas, durante el streaming y al volver a abrir la conversación.
- Los enlaces normales mantienen su texto descriptivo y su destino.

## Mensajes en cola mientras el modelo responde

### Comportamiento solicitado

Si se envía un mensaje durante una respuesta, debe quedar en cola y enviarse automáticamente cuando termine el turno actual. Si se pulsa Enter de nuevo con el campo vacío y hay un mensaje pendiente, debe detenerse la generación y enviarse el siguiente mensaje inmediatamente.

### Propuesta de interfaz

Mostrar la cola entre la respuesta y el campo de escritura. El campo queda libre para preparar otro mensaje.

```text
EN COLA · Se enviará al terminar
Añade también una comparación de precios…
                              [Enviar ahora ↵] [×]

Escribe otro mensaje…
```

Con varios mensajes, mostrar `En cola · 3` y una fila compacta por mensaje, en orden de envío. Cada mensaje se procesa en su propio turno.

### Teclado y acciones

| Estado y acción | Resultado propuesto |
|---|---|
| El modelo responde y se pulsa Enter con texto | Añadir el mensaje a la cola y vaciar el campo |
| El modelo responde, hay cola y se pulsa Enter con el campo vacío | Interrumpir la respuesta y enviar el siguiente mensaje |
| El modelo termina normalmente y hay cola | Enviar automáticamente el siguiente mensaje |
| Se escribe otro mensaje y se pulsa Enter | Añadirlo al final de la cola |
| Se pulsa Enviar ahora | Interrumpir la respuesta y enviar el siguiente mensaje |
| Se pulsa un mensaje pendiente | Permitir editarlo |
| Se pulsa × en un mensaje pendiente | Retirarlo de la cola |

Mientras el modelo responda y haya cola, mostrar una ayuda contextual junto al campo: `↵ interrumpir y enviar siguiente`. El botón visible Enviar ahora permite descubrir la acción sin conocer el atajo.

### Criterios de aceptación

- El texto enviado queda visible en la cola; nunca desaparece sin indicar su estado.
- La respuesta interrumpida se conserva y se marca como Interrumpida.
- El siguiente turno recibe el contexto disponible, incluida la respuesta parcial interrumpida.
- Mantener Enter pulsado no añade un mensaje y lo envía inmediatamente: debe soltarse la tecla antes de aceptar el segundo Enter.
- Enter con texto añade a la cola; solo Enter con el campo vacío activa el envío inmediato.
- Los mensajes mantienen el orden y se envían una sola vez, incluso si coinciden el fin de la generación y una acción manual.
- El comportamiento se mantiene en los modos API y CLI.

### Decisiones pendientes

Antes de implementar la cola, concretar qué ocurre con los pendientes al cambiar de conversación, cerrar Boltbar, detener manualmente una respuesta o recibir un error del proveedor. También debe definirse la edición de mensajes con adjuntos. Estas situaciones no deben provocar envíos inesperados ni pérdida silenciosa de mensajes.

## Decisiones e implementación

Implementado el 19 de octubre de 2026. La revisión de la propuesta contra el código cambió varios puntos.

### Enlaces y citas

- **Causa real del pegado.** El stream de Claude escribía la cita en cuanto llegaba el `citations_delta`, sin espacio posterior y en una posición que dependía del orden de los eventos. Ahora las citas de cada bloque se guardan hasta `content_block_stop`, quedan detrás de la afirmación citada y antes de un salto de línea, y el espacio posterior solo se añade si el texto siguiente empieza por letra o número; la puntuación y el énfasis de cierre no se tocan. El camino de OpenAI (`WebCitations.markdown`) tenía el mismo hueco y aplica la misma regla.
- **Chats ya guardados.** Arreglar solo el streaming no corrige el texto antiguo. Al renderizar, las citas también se separan de las palabras vecinas, así que `[1](…)If` se ve bien al reabrir una conversación antigua.
- **Sin tooltip con el dominio.** El `Text` de SwiftUI no admite tooltips por fragmento y el hover no es accesible ni descubrible. En su lugar, cada respuesta con citas muestra una línea `SOURCES 1 2 swift.org 3 apple.com`; al pasar el ratón sobre ella se listan las direcciones completas.
- **Sin flecha `↗` ni esquinas redondeadas.** `Text` no puede redondear ni dar padding a un fragmento. La cita es el número sobre un fondo tintado con espacios finos, un rasgo que no depende del color. La flecha duplicaba el ancho y hacía ruidosas las citas consecutivas.
- Los enlaces descriptivos conservan su texto y llevan un subrayado fino en color de acento.

### Mensajes en cola

- **Varios pendientes van juntos en un turno.** El modelo ve todo lo añadido y solo hay una espera. En el hilo cada mensaje sigue apareciendo por separado.
- **Enter vacío protegido.** Se ignoran la repetición de tecla y cualquier Enter en los 0,6 s posteriores a encolar, para que un doble toque no corte la respuesta.
- **Regla única para los casos pendientes.** La cola solo avanza sola tras un turno terminado con éxito. Stop, un error del proveedor, cambiar de conversación, ⌥Space o cerrar Boltbar la dejan en pausa, visible y guardada con la conversación. Solo se reanuda con una acción explícita: Enter, Enviar ahora o Reintentar.
- **Edición en el campo de escritura.** Al pulsar un pendiente, su texto y sus adjuntos pasan al campo de escritura. El mensaje conserva su posición, la cola espera mientras se edita y Esc cancela sin perder nada. Para no pisar un borrador, solo se edita con el campo vacío.
- **Botón principal.** Mientras el modelo responde, con texto el botón encola y Stop aparece al lado como botón secundario. Antes, pulsarlo para "enviar" detenía la respuesta.
- **Enviar ahora** está en la cabecera de la cola, no en cada fila, porque los pendientes se envían juntos y en orden.
- **Respuestas interrumpidas.** Se conservan y se marcan como Interrumpida. Al modelo le llegan con una nota de que se cortaron. Una respuesta detenida antes del primer token ya no se envía vacía, algo que antes provocaba un HTTP 400 en el siguiente mensaje.
- La interfaz está en inglés, como el resto de Boltbar: `QUEUED`, `Send now ↵`, `↵ interrupt and send`, `INTERRUPTED`.

### Limitación conocida

⌥Space siempre abre una conversación nueva y detiene la respuesta en curso. Si se oculta Boltbar con Esc durante una respuesta con cola y se vuelve con ⌥Space, la cola queda en pausa en el historial en lugar de enviarse. Cambiar ese comportamiento queda fuera de este cambio.

