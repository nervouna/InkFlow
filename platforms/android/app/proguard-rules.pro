# JNI_OnLoad resolves this exact binary class and registers all owner-token
# method descriptors. The acceptance gate audits every release-Dex signature.
-keep class io.damao.inkflow.engine.NativeBridge {
    native <methods>;
}

# Constructors are called from the JNI bridge when creating immutable updates.
-keep class io.damao.inkflow.engine.NativeEngineUpdate {
    <init>(...);
}
-keep class io.damao.inkflow.engine.EngineCandidate {
    <init>(...);
}
