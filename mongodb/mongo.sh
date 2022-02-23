conn = new Mongo();
db.auth("admin", "mongo")
use shakespeare;
db.createCollection("quotes");
db.quotes.insertOne({'publication':'Romeo and Juliet', 'text':'What\'s in a name? That which we call a rose by any other word would smell as sweet...'})