/// What the orb is doing, as it shows.
///
/// [connecting] is a call being set up (the cyan turning ring); [listening]
/// and [speaking] are a live call, whose turn it is; [thinking] is a typed
/// turn the model is working on; [operating] is the agent moving the app.
enum OrbState { idle, connecting, listening, thinking, speaking, operating }
