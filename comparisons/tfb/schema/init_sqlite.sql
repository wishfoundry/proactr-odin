-- TechEmpower-compatible seed data (SQLite).
-- World: 10_000 rows; Fortune: 12 TE rows.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

DROP TABLE IF EXISTS world;
DROP TABLE IF EXISTS fortune;

CREATE TABLE world (
  id INTEGER PRIMARY KEY NOT NULL,
  randomNumber INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE fortune (
  id INTEGER PRIMARY KEY NOT NULL,
  message TEXT NOT NULL
);

-- 10k World rows (TE scale)
WITH RECURSIVE seq(i) AS (
  SELECT 1
  UNION ALL
  SELECT i + 1 FROM seq WHERE i < 10000
)
INSERT INTO world (id, randomNumber)
SELECT i, abs(random() % 10000) + 1 FROM seq;

INSERT INTO fortune (id, message) VALUES
  (1, 'fortune: No such file or directory'),
  (2, 'A computer scientist is someone who fixes things that aren''t broken.'),
  (3, 'After enough decimal places, nobody gives a damn.'),
  (4, 'A bad random number generator: 1, 1, 1, 1, 1, 4.33e+67, 1, 1, 1'),
  (5, 'A computer program does what you tell it to do, not what you want it to do.'),
  (6, 'Emacs is a nice operating system, but I prefer UNIX. — Tom Christaensen'),
  (7, 'Any program that runs right is obsolete.'),
  (8, 'A list is only as strong as its weakest link. — Donald Knuth'),
  (9, 'Feature: A bug with seniority.'),
  (10, 'Computers make very fast, very accurate mistakes.'),
  (11, '<script>alert("This should not be displayed in a browser alert box.");</script>'),
  (12, 'フレームワークのベンチマーク');
