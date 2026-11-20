# Thimble user guide

To connect a real account you need Google Chat enabled for your Google Workspace account and a **Desktop OAuth
client JSON file** from that organization. If a teammate has already set up the project, ask them for the file
and go straight to [Sign in on your Mac](#sign-in-on-your-mac).

## Build and try the app

1. On a Mac running **macOS 27 or later**, install the full Xcode app with the macOS 27 SDK and Swift 6.4 or later.
   Open Xcode once to finish setup. In **Xcode → Settings → Locations**, select that Xcode under **Command Line Tools**.
2. Install XcodeGen. With Homebrew, run `brew install xcodegen`. [XcodeGen installation](https://formulae.brew.sh/formula/xcodegen)
3. Download or clone this repository. In Terminal, open the folder containing `Makefile` and build the sample app.

   ```sh
   make build && make fake
   ```

   A window with sample workspaces and conversations confirms that the build works. The build uses an available Apple
   Development signing identity and falls back to ad-hoc signing. A stable development identity is preferable for
   continued use because the app stores login credentials in Keychain.

4. When you’re ready to sign in, **quit the sample app with ⌘Q**. Closing the window leaves it running in the menu bar.
   Start the same build in live mode.

   ```sh
   make run
   ```

## Set up Google Cloud

Do this **once per Workspace organization**. Use a work account with permission to create or select a project in the
organization, enable APIs, and create OAuth credentials. If your organization manages those centrally, send this section
to your administrator. Keep the same project selected in the top bar throughout.

### 1. Create the project and enable two APIs

1. Choose **New project**, give it a name such as `Chat Desktop`, and select your Workspace organization as the parent.
   Once the project is created, select it in the project picker. [Create a project](https://console.cloud.google.com/projectcreate)
2. Open each of these API Library pages and click **Enable**. **Manage** means that API is already enabled.
   - **Google Chat API** handles spaces, messages, threads, and reactions. [Enable Google Chat API](https://console.cloud.google.com/apis/library/chat.googleapis.com)
   - **People API** supplies directory search and profile photos. [Enable People API](https://console.cloud.google.com/apis/library/people.googleapis.com)

### 2. Configure Google sign-in

Go to **Google Auth Platform → Branding**. In a new project click **Get started**. Enter an app name people will
recognize, such as `Chat Desktop`, and choose a **User support email**. Under **Audience**, choose **Internal**.
Enter a **Contact email**, review Google’s policy, and finish with **Create**. If this wizard has already been completed,
check the existing settings under **Branding** and **Audience**. [Open Branding](https://console.cloud.google.com/auth/branding) · [Google’s consent screen guide](https://developers.google.com/workspace/guides/configure-oauth-consent)

The Mac app requests its scopes when each person signs in. Google’s internal-only setup lets you skip scope entry in
the console. If your administrator requests the scope list, or you need to enter it under **Data Access → Add or remove
scopes**, use the values below. [Open Data Access](https://console.cloud.google.com/auth/scopes)

<details>
<summary>OAuth scopes requested by Thimble</summary>

The required scopes identify the signed-in account, list spaces and members, read and search messages, send messages
and attachments, start direct messages, react, sync read state, and read space notification settings and custom emoji.
Google’s console lists the app’s `email` scope as `https://www.googleapis.com/auth/userinfo.email`.

```text
openid
https://www.googleapis.com/auth/userinfo.email
https://www.googleapis.com/auth/chat.spaces.readonly
https://www.googleapis.com/auth/chat.memberships.readonly
https://www.googleapis.com/auth/chat.messages.readonly
https://www.googleapis.com/auth/chat.messages.create
https://www.googleapis.com/auth/chat.messages.reactions
https://www.googleapis.com/auth/chat.users.readstate
https://www.googleapis.com/auth/chat.users.spacesettings
https://www.googleapis.com/auth/chat.customemojis.readonly
https://www.googleapis.com/auth/chat.spaces.create
```

The app also requests `https://www.googleapis.com/auth/directory.readonly` for Workspace directory features.
Sign-in can complete without this optional grant. Google classifies message-read access as restricted.
[Google Chat scope descriptions](https://developers.google.com/workspace/chat/authenticate-authorize#chat-api-scopes)

</details>

### 3. Save the Chat app configuration

Open **Google Chat API → Configuration**. Under **Application info**, fill in these three fields.
[Open Chat API Configuration](https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat)

| Field | Example |
| --- | --- |
| App name | `Chat Desktop` |
| Avatar URL | Use a publicly reachable HTTPS URL for a square PNG or JPEG. For initial setup, Google’s sample is `https://www.gstatic.com/dynamite/images/quickstart-app-avatar.png`. |
| Description | `Read and reply to Workspace conversations from a Mac.` |

Leave **Enable interactive features** off and click **Save**. The Mac connects directly to Google using the signed-in
person’s account. This setup needs no bot server, webhook, or Pub/Sub topic. Saving the Chat configuration matters
for sending messages and updating read state. [Google’s Chat configuration guide](https://developers.google.com/workspace/chat/configure-chat-api)

### 4. Download the Desktop client file

1. Open **Google Auth Platform → Clients → Create client**. [Open Clients](https://console.cloud.google.com/auth/clients)
2. Set **Application type** to **Desktop app**, enter a name such as `Chat Desktop for macOS`, and click **Create**.
   The Desktop type supports the app’s local browser callback automatically.
3. Click **Download JSON** in the creation dialog and keep the downloaded file outside your source checkout. The app
   imports the file as downloaded. If you inspect it, its top-level key should be `installed`.
4. Give that file to the people in **this Workspace organization** who will use Thimble through your normal internal
   sharing channel. Each person signs in with their own Google account. [Google’s desktop credential guide](https://developers.google.com/workspace/guides/create-credentials#desktop-app)

## Sign in on your Mac

1. Open the live app. Click **Choose client file and sign in…** and select the downloaded JSON. If the app shows a
   saved project, choose **Sign in with Google** for that project or **Use another client file…** to switch.
2. Your default browser opens Google’s consent screen. Choose the Workspace account that belongs to the project’s
   organization, grant the required permissions, and continue. Keep Thimble running until the browser returns
   control to the app.
3. Back on the Mac, open a familiar space or DM. Seeing its recent messages under the expected account badge confirms
   that sign-in and reading work. To check sending, use a conversation where you intend to post.

For another account, open **Settings → Accounts → + Add account**. Choose **Using the saved client** for the same
organization, or **Using a client file…** for another organization’s project. The app keeps separate credentials
and an encrypted message cache for each account.

## Everyday use

| To | Use |
| --- | --- |
| Switch conversations or accounts | **⌘K** opens the conversation switcher. The menu beside the sidebar's search field, or **⌥⌘1** through **⌥⌘9**, shows one account; **⌥⌘0** shows all of them again. With all accounts showing, each conversation carries its account's badge. |
| Find an older message | **⌘F** searches one or all workspaces. Select a match for surrounding messages. |
| Send or reply | The badge at the start of the message field shows which account sends. **Return** sends and **Shift-Return** inserts a line break. Click a message's replies to open its thread in place and reply there. |
| See who's in a conversation | Click the conversation's name at the top. Hover a person to message them or mention them in your reply. The **ⓘ** button beside search shows the conversation's details: when it was created and last active, how replies work, its history and guest settings, and your notifications. |
| Hide the sidebar | Click the sidebar button at the top of the sidebar, or press **⌃⌘S**. |
| Look at an image | Click it. Zoom with **⌘+** and **⌘−**, a pinch or **⌘**-scroll; **⌘0** shows actual size and **⌘9** fits it. **←** and **→** step through the conversation's images. |
| Renew account access | In **Settings → Accounts**, use the account’s **… → Reconnect to Google…**. Drafts and queued sends stay on the Mac. |
| Remove an account | Choose **… → Remove from this Mac…**. This clears the local cache, drafts, and queued messages. Messages already sent stay in Google Chat. |

## If setup gets stuck

| Symptom | What to check |
| --- | --- |
| **Add account** is disabled and Settings says **Sample data mode** | Quit with **⌘Q** and start the app with `make run`. |
| **Internal** is unavailable, or Google says `org_internal` | Check that the Cloud project belongs to your Workspace organization and that you chose an account in that same organization. |
| The app rejects the JSON file | Download a **Desktop app** OAuth client. A web client has a `web` key, and a service-account key has a different format. |
| Google says an administrator blocked access | Give your Workspace admin the **OAuth client ID** and the scope list above. They can review access under **Security → Access and data control → API controls**. [Workspace admin instructions](https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data) |
| Google says the Chat API is disabled, or reading works but sending fails | In the project that issued the JSON, verify **Google Chat API → Manage → Configuration** is saved. Also check that your account can post in that space in Google Chat. |
| Sign-in reports missing permissions | Sign in again and select all required Chat permissions. If the client was replaced, choose **Reconnect using a client file…** in Settings. |
| Chats work but directory search returns nothing | Check that the **People API** is enabled, directory access was granted, and your Workspace allows directory sharing. Contacts from existing conversations are also available. |
