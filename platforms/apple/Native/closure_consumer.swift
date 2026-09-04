import InkFlowEngine

guard inkflow_engine_api_version() == INKFLOW_ENGINE_API_VERSION else {
    fatalError("InkFlow engine API version mismatch")
}
