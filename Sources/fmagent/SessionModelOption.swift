import ACPKit
import Foundation

/// The `model` session config option advertised by fmagent.
///
/// Foundation Models exposes exactly one model (on-device), so this is a
/// single-entry `select`: it renders a truthful model row in clients and
/// gives us the `session/set_config_option` plumbing for free if variants
/// ever appear.
public enum SessionModelOption {
    public static var id: SessionConfigId { "model" }
    public static var onDevice: SessionConfigValueId { "on-device" }

    public static func configOption() -> SessionConfigOption {
        .select(
            id: id,
            name: "Model",
            description: "Inference model for this session.",
            category: .model,
            select: SessionConfigSelect(
                currentValue: onDevice,
                options: .ungrouped([
                    SessionConfigSelectOption(
                        value: onDevice,
                        name: "On-device",
                        description: "Apple Foundation Models (on-device)")
                ])
            ),
            meta: nil
        )
    }
}
