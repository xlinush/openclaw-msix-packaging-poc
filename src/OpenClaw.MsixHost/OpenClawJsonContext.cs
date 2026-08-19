using System.Text.Json.Serialization;

namespace OpenClaw.MsixHost;

[JsonSerializable(typeof(PayloadMetadata))]
[JsonSerializable(typeof(PayloadInventory))]
internal sealed partial class OpenClawJsonContext : JsonSerializerContext;
