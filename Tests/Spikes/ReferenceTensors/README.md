# ReferenceTensors (D-24 / CONTRACTS C-7 spike-parity sidecars)

Captured model outputs of the PINNED manifest entries on the committed fixtures (regenerable: `python3 Tests/Spikes/swiftf0_real.py --export-ref` and `... silero_real.py --export-ref`). Consumed by P-208 parity tests (Python reference vs Swift/ORT outputs, tolerance-based). The model SHA travels INSIDE the npz (`_model_sha256`) — parity asserts it matches the manifest entry, so a model bump without regeneration fails loudly.
