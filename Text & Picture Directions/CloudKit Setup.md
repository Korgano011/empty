# CloudKit Setup — Text & Picture Directions

The repository is the app's **public** CloudKit database in the container
`iCloud.com.thomasdaly.TextPictureDirections` (bundle id
`com.thomasdaly.TextPictureDirections`, team 28WK9PUKJ7).

## 1. Create the record types (Development)

Run the app from Xcode on an iPhone signed in to iCloud, with the orange
"Test mode" banner **off** in the Repository tab, and do each once:

- **Text** tab → search a place → open it → **Save to Repository** (creates `Directions`).
- **Indoor** tab → **Record a Route** → add a step or two (tap **Landmark** and
  attach a photo) → **I've Arrived** → **Save** → open it → **Share to
  Repository** (creates `IndoorRoute`).
- Open someone else's item — or use a second Apple ID — and **⋯ → Report…**
  (creates `Report`).

## 2. Add indexes

icloud.developer.apple.com → **CloudKit Database** → this container →
**Development** → **Schema → Indexes**:

| Record type  | Field           | Index type |
|--------------|-----------------|------------|
| Directions   | recordName      | Queryable  |
| Directions   | createdTimestamp| Sortable   |
| Directions   | createdBy       | Queryable  |
| IndoorRoute  | recordName      | Queryable  |
| IndoorRoute  | createdTimestamp| Sortable   |
| IndoorRoute  | createdBy       | Queryable  |

Without these the Repository tab shows an error such as
"Field 'recordName' is not marked queryable".

## 3. Viewing and moderating

**Records → Public Database → `_defaultZone`**, record type `Directions`,
`IndoorRoute`, or `Report` → **Query Records**. Each `Report` has
`itemType`, `itemID` (the record name of the reported item), `title`, and
`reason`. To remove reported content, query that record type and delete
the record, then delete the Report. App Review expects reports to be acted
on within 24 hours.

## 4. Before release

**Deploy Schema Changes…** to Production (record types and indexes), and
again whenever a field or index is added.
