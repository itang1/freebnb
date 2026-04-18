# FreeBNB

A free home-sharing app for iOS, built with SwiftUI. Hosts list their spaces, guests find a place to stay.

## File Structure

```
freebnb/
├── App/             # Entry point and root navigation
├── Auth/            # Sign-in, authentication state
├── Homes/           # Listing browsing, filtering, and detail views
├── Messaging/       # In-app messaging between hosts and guests
├── Profile/         # User profile
├── Onboarding/      # First-launch onboarding flow
├── Info/            # About, FAQ, how it works, guest tips, safety
└── Shared/          # Extensions and sample data
```

The structure is organized by feature and is set up to support the MVVM framework.
