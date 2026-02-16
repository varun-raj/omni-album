# CloudKit setup for immich-share

The app stores added albums in CloudKit. You must create the **Album** record type in the CloudKit Dashboard before saving or querying will work.

## 1. Open CloudKit Dashboard

- Go to [iCloud Dashboard](https://icloud.developer.apple.com/)
- Sign in with your Apple Developer account
- Select the container **iCloud.com.skcript.immich-share** (or create it under your App ID’s iCloud capability first)

## 2. Create the Album record type

1. In the left sidebar, open **Schema** → **Record Types**
2. Click **+** (or “Add Record Type”)
3. Set **Record Type** name to: `Album`
4. Add these fields (click **+** under Field Names):

| Field Name              | Type   | Indexed (optional) |
|-------------------------|--------|--------------------|
| `id`                    | String | ✓ (Queryable)      |
| `albumName`             | String |                    |
| `albumThumbnailAssetId` | String |                    |
| `baseURL`               | String |                    |
| `shareKey`              | String |                    |
| `albumId`               | String |                    |
| `assetCount`            | Int64  |                    |
| `createdAt`             | Date/Time | ✓ (Queryable, Sortable) |

5. Click **Save**
6. In **Schema**, click **Deploy to Development** (and later **Deploy to Production** when you ship)

## 3. Run the app again

After the **Album** record type exists and is deployed to Development, add an album again; save and fetch should succeed.
