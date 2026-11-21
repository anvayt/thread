# Product

## Register

product

## Users

People who meet many others in a short time and are expected to remember them: founders raising a round, people in client meetings, at networking events, conferences and interviews. They use Thread standing in a room, mid-conversation, wearing Meta glasses with the phone in a hand or a pocket. They can give the phone a second or two, one-handed, and often do not look at it at all and only hear a line in their ear.

The job: know who is in front of them and what was left open, without looking like they are checking a device.

Whoever sets it up is a developer who runs the backend on their own computer and reads the Connect tab when something does not work.

## Product Purpose

Thread remembers the people you meet. One action captures a face and what the person says. The next time that face appears, it gives back a name, a company and the one thing worth saying next. It works when the wearer gets the right line within a few seconds and nothing on screen needs reading during a conversation.

## Brand Personality

Plain, quiet, trustworthy. The app should look like it came with the phone. The reference is Apple's own apps on iOS 26: Contacts for people, Camera and Voice Memos for capturing, the AirPods page in Settings for the glasses, and search in the tab bar. The only branding is the name, Thread, set in the system font, and the app icon (see `thread-backend/assets/BRAND.md`).

Voice: short, literal sentences. Buttons, menu items, switches, titles and section headers are in title case, as Apple writes them ("Tap to Start Meet", "Add Sample People"); everything that is a sentence is in sentence case. Say what happened and what to do next. Never sell inside the product.

## Anti-references

- Anything that reads as generated: a dark theme with a purple or neon accent, glows and gradients, every section in an identical rounded card, tiny all-caps labels above sections, status pills, sparkle icons, marketing copy on working screens.
- Debug output presented as interface, such as state strings like "lens: idle".
- A custom control where the system has one.

## Design Principles

1. It should disappear. In a conversation the wearer cannot read, so show one thing at a time and make the main action reachable without looking.
2. System first. Use the platform's own controls, colours, type and navigation. Liquid Glass is for the controls that float over content (the tab bar, toolbar buttons, the Meet controls, actions under a name), never for the content itself. Branding is the name and the app icon, and nothing else.
3. Say it once, plainly. Explanations belong in How Thread Works, an empty state or a short footer, not on the working screens.
4. Never guess in front of someone. Uncertain states (no match, no face, backend unreachable) are stated quietly and specifically.
5. Experimental means labelled and off. Anything untested on hardware is opt-in and says so.

## Accessibility & Inclusion

Follow the system: Dynamic Type, light and dark appearance, Reduce Motion, VoiceOver labels on every control, and contrast at WCAG AA, which the system colours meet. No information by colour alone. These are assumed defaults; the owner has not set specific requirements.
