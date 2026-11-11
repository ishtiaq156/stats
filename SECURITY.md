# Security

Please avoid posting pairing passcodes, phone credentials, or private network details in public issues. If you find a security vulnerability, contact the repository owner privately through their GitHub profile before disclosing details publicly.

The current local prototype uses a five-minute, five-digit pairing passcode with SPAKE2 and key confirmation. Each enrolled phone receives a distinct 256-bit credential stored in Keychain; subsequent metric requests use AES-GCM. Refreshing the passcode invalidates the previous pairing session, while revoking a phone removes only that phone's authorization.

The pairing implementation and underlying SPAKE2 dependency have not received an independent security audit. Broader physical-device testing and protocol review remain necessary before a stable release and wider deployment. Keep this preview build on a trusted local network.
