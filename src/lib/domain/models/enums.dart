/// Connection state of a transport / machine controller.
enum ConnectionState { disconnected, connecting, connected, error }

/// Which processor we are currently talking to on the shared serial bus.
enum SessionMode { sewingMachine, embroideryModule }

/// Where an embroidery file lives on the machine.
enum StorageLocation { embroideryModuleMemory, pcCard }

/// High-level session state as reported by the machine (0x57FF80).
enum SessionState { unknown, sewing, embroidery }
