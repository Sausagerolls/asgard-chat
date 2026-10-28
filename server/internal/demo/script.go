package demo

// line is one seeded message. From is 1 or 2 (the first or second account),
// Chat is "dm" or "group", ReplyTo is the 1-based index of an earlier line,
// and React is an emoji the other account adds.
type line struct {
	From    int
	Chat    string
	Text    string
	ReplyTo int
	React   string
}

var script = []line{
	{From: 1, Chat: "dm", Text: "Hey! Welcome to Asgard 👋"},
	{From: 2, Chat: "dm", Text: "Thanks! So this runs on our own server?"},
	{From: 1, Chat: "dm", Text: "Yep. Everything is end-to-end encrypted, so even the server can't read what we send."},
	{From: 2, Chat: "dm", Text: "Nice. Can I send photos and voice notes too?", React: "👍"},
	{From: 1, Chat: "dm", Text: "All of it: photos, files, voice notes, polls. Try holding the mic button.", ReplyTo: 4},
	{From: 2, Chat: "dm", Text: "Swipe right on a message to reply to it, like this 😄", ReplyTo: 3},
	{From: 1, Chat: "dm", Text: "Long-press a message to react, edit or delete it.", React: "❤️"},

	{From: 1, Chat: "group", Text: "This is the App Review group."},
	{From: 2, Chat: "group", Text: "Groups support mentions, pinned messages and member roles."},
	{From: 1, Chat: "group", Text: "Tap the group name at the top to see members and settings.", React: "🙌"},
	{From: 2, Chat: "group", Text: "Anything sent here is delivered to every member's devices, encrypted for each one."},
}
