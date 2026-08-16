import '../hosted_config.dart';

/// Non-web platforms are never server-hosted.
HostedConfig readHostedConfig() => HostedConfig.none;
