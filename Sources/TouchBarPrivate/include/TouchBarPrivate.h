#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// YES si este macOS permite mostrar barras "modales del sistema"
/// (las que se ven encima de cualquier app, como el Now Playing de Apple).
BOOL OBSystemModalAvailable(void);

/// Muestra la barra en toda la Touch Bar.
/// placement < 0 = variante sin "placement" · 0, 1… = variante con "placement".
void OBPresentSystemModal(NSTouchBar *touchBar, long long placement, NSTouchBarItemIdentifier _Nullable trayIdentifier);
/// La recoge dentro de su botón de la Control Strip.
void OBMinimizeSystemModal(NSTouchBar *touchBar);
/// La quita del todo.
void OBDismissSystemModal(NSTouchBar *touchBar);

/// Botón propio dentro de la Control Strip.
void OBAddSystemTrayItem(NSTouchBarItem *item);
void OBRemoveSystemTrayItem(NSTouchBarItem *item);
void OBSetControlStripPresence(NSTouchBarItemIdentifier identifier, BOOL present);

/// La "X" que el sistema dibuja a la izquierda de una barra modal.
void OBSetShowsCloseBoxWhenFrontMost(BOOL shows);

/// Luz del teclado (CoreBrightness, privado).
BOOL OBKeyboardLightAvailable(void);
float OBKeyboardLightGet(void);
/// commit = NO para cambios rápidos (no se guarda como preferencia del usuario).
void OBKeyboardLightSet(float level, BOOL commit);
BOOL OBKeyboardAutoBrightnessEnabled(void);
void OBKeyboardSetAutoBrightness(BOOL enabled);
/// Evita que la luz se apague por inactividad mientras suena la música.
void OBKeyboardSuspendIdleDimming(BOOL suspend);

NS_ASSUME_NONNULL_END
