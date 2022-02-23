conn = new Mongo();
db.auth("admin", "mongo")
use shakespeare;
db.quotes.find().pretty();