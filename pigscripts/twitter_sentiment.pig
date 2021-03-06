/*
 * Finds which words show up most frequently in tweets expressing positive and negative
 * sentiments relative to the word's frequency in the total corpus of tweets.
 *
 * Recommended cluster size with default parameters: 5
 * Approximate running time with recommended cluster size: 40 minutes
 * (first mapreduce job will take almost all of the time, so the progress meter will be inaccurate)
 *
 * Words are filtered so that only those with length >= MIN_WORD_LENGTH are counted.
 *
 * Postive/negative associations (the words with the greatest relative frequency for positive/negative tweets)
 * are filtered so as not to include the words which signalled positive/negative sentiment in the first place. 
 * This way, you don't just get a list of words like "great" and "awesome".
 * 
 * All text is converted to lower case before being analyzed.
 * Words with non-alphabetic characters in the middle of them are ignored ("C3P0"), 
 * but words with non-alphabetic characters on the edges simply have them stripped ("totally!!!" -> "totally")
 */

%default OUTPUT_PATH 's3n://mortar-example-output-data/$MORTAR_EMAIL_S3_ESCAPED/twitter_sentiment'

%default MIN_WORD_LENGTH '5'

-- for reference:
--     the 8,000'th most-frequent word in the English language has a frequency of ~ 0.00001
--     the 33,000'th most-frequent word in the English language has a frequency of ~ 0.000001
--     the 113,000'th most-frequent word in the English language has a frequency of ~ 0.0000001
%default MIN_ASSOCIATION_FREQUENCY '0.00000125'
%default MAX_NUM_ASSOCIATIONS '100'

-- Load Jython UDF's and Pig macros

REGISTER '../udfs/jython/twitter_sentiment.py' USING streaming_python AS twitter_sentiment;
REGISTER '../udfs/jython/words_lib.py' USING streaming_python AS words_lib;

IMPORT '../macros/words.pig';

-- Load tweets
-- To improve performance, we tell the JsonLoader to only load the field that we need (text)

tweets = LOAD 's3n://twitter-gardenhose-mortar/tweets' 
         USING org.apache.pig.piggybank.storage.JsonLoader('text: chararray');

-- Split the text of each tweet into words and calculate a sentiment score

tweets_tokenized        =   FOREACH tweets GENERATE words_lib.words_from_text(text) AS words;
tweets_with_sentiment   =   FOREACH tweets_tokenized 
                            GENERATE words, twitter_sentiment.sentiment(words) AS sentiment: double;

SPLIT tweets_with_sentiment INTO
    positive_tweets IF (sentiment > 0.0),
    negative_tweets IF (sentiment < 0.0);

-- Find the frequency of each word of at least MIN_WORD_LENGTH letters in all the tweets
-- (frequency = the probability that a random word in the corpus is the given word)
-- The macros used are in macros/words.pig

tweet_word_totals       =   WORD_TOTALS(tweets_tokenized, $MIN_WORD_LENGTH);
tweet_word_frequencies  =   WORD_FREQUENCIES(tweet_word_totals);

-- Find the frequencies of words that show up in tweets expressing positive sentiment, 
-- and divide them by the frequencies of those words in the entire tweet corpus
-- to find the relative frequency of each word. 

pos_word_totals         =   WORD_TOTALS(positive_tweets, $MIN_WORD_LENGTH);
pos_word_frequencies    =   WORD_FREQUENCIES(pos_word_totals);
pos_rel_frequencies     =   RELATIVE_WORD_FREQUENCIES(pos_word_frequencies, tweet_word_frequencies, $MIN_ASSOCIATION_FREQUENCY);

-- Take the top 100 of these positively associated words, 
-- filtering out the words which signalled the positive sentiment in the first place (ex. "great", "awesome").

pos_associations        =   ORDER pos_rel_frequencies BY rel_frequency DESC;
pos_assoc_filtered      =   FILTER pos_associations BY (twitter_sentiment.in_word_set(word, 'positive') == 0);
top_pos_associations    =   LIMIT pos_assoc_filtered $MAX_NUM_ASSOCIATIONS;

-- Do the same with negative words.

neg_word_totals         =   WORD_TOTALS(negative_tweets, $MIN_WORD_LENGTH);
neg_word_frequencies    =   WORD_FREQUENCIES(neg_word_totals);
neg_rel_frequencies     =   RELATIVE_WORD_FREQUENCIES(neg_word_frequencies, tweet_word_frequencies, $MIN_ASSOCIATION_FREQUENCY);
neg_associations        =   ORDER neg_rel_frequencies BY rel_frequency DESC;
neg_assoc_filtered      =   FILTER neg_associations BY (twitter_sentiment.in_word_set(word, 'negative') == 0);
top_neg_associations    =   LIMIT neg_assoc_filtered $MAX_NUM_ASSOCIATIONS;

-- Remove any existing output and store to S3

rmf $OUTPUT_PATH/positive;
rmf $OUTPUT_PATH/negative;
STORE top_pos_associations INTO '$OUTPUT_PATH/positive' USING PigStorage('\t');
STORE top_neg_associations INTO '$OUTPUT_PATH/negative' USING PigStorage('\t');
