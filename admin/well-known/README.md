# Apple App Site Association

`apple-app-site-association.json` is what makes an invite link open the FreeBNB
app instead of Safari. iOS fetches it, over https and with no redirects, from

    https://freebnb-6814a.web.app/.well-known/apple-app-site-association

It lives here without the leading dot, and `firebase.json` rewrites the
`.well-known` path onto it. That is deliberate: Firebase Hosting's default
`ignore` of `**/.*` would otherwise leave the file out of the deploy, and the
failure is silent — links keep opening Safari with nothing in the logs to say
why. The `.json` extension also gets it served as `application/json`, which
Apple requires.

## Before this works: paste the Team ID

`appIDs` currently reads `REPLACE_WITH_TEAM_ID.com.poodlestrategy.freebnb`.
Replace `REPLACE_WITH_TEAM_ID` with the ten-character Apple Developer Team ID
(Membership details in the developer portal, or the `DEVELOPMENT_TEAM` build
setting once the project is signed). `InviteLinkTests` fails while the
placeholder is present, so this cannot ship half-done by accident.

Both ends have to agree, and neither is checked at runtime:

- this file names `TEAMID.com.poodlestrategy.freebnb`
- `freebnb/freebnb.entitlements` claims `applinks:freebnb-6814a.web.app`
- the App ID in the developer portal has Associated Domains enabled

## Deploying and checking it

    firebase deploy --only hosting

Hosting is on the free Spark plan, so this needs no billing change.

    curl -sI https://freebnb-6814a.web.app/.well-known/apple-app-site-association

Expect `200` and `content-type: application/json`. A `404` means the rewrite
didn't deploy; `application/octet-stream` means it is being served from a path
without the `.json` extension. iOS caches the file, so reinstall the app after
changing it rather than expecting a live update.
