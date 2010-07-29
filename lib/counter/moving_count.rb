require 'active_record'

# Capture counts, then aggregate them across time. Think of this as an rrdtool for counts.
#
# === Setup
# Inherit from this class
#
#  class PageView < MovingCount
#  end
#
# Then drop the following into a migration:
#
#  create_table :page_views, :force => true do |t|
#    t.string   :category,      :null => false
#    t.integer  :count,         :null => false, :default => 0
#    t.datetime :sample_time,   :null => false
#  end
#
#  add_index :page_views, :category
#
# Two optional class-level settings:
# * *set_history_to_keep*, depth of history to keep in seconds - defaults to 1 hour of history
# * *set_sample_interval*, minimum distance between samples in seconds (enforced at record time) - defaults to 1 minute
#
# === Recording counts
#
#  PageView.record_counts(Time.at(1280420630)) do |c|
#    c.increment('key1')
#    c.increment('key1')
#    c.increment('key2')
#  end
#
# records observed counts for Thu Jul 29 12:23:50.  You can omit the param to record counts at Time.now.
#
# A runtime error will be raised if the sample is too close to the previous (for example, sample_interval is 60s and you tried to record 
# a sample at 50s).  This prevents accidental duping of counts on restarts, etc.
#
# === Checking totals
#
#  PageView.totals
#
# returns a [key,count] array of all keys ordered by count.  An optional <tt>limit</tt> param restricts results to the top n.
class MovingCount < ActiveRecord::Base
  self.abstract_class = true
  
  # Sets the depth of history to keep, in seconds.
  # Default is 1 hour.
  def self.set_history_to_keep time_range
    @history_to_keep = time_range
  end
  
  def self.history_to_keep
    @history_to_keep || 1.hour
  end
  
  # Sets the minimum distance between recorded samples, in seconds.
  # Default is 1 minute.
  def self.set_sample_interval interval
    @sample_interval = interval
  end
  
  def self.sample_interval
    @sample_interval || 1.minute
  end
  
  # Records counts at the specified timestamp.  If timestamp omitted, counts are recorded at Time.now.
  # Yields a Counter instance, all standard methods apply.
  # Raises an exception if the timestamp would fall too soon under the <tt>sample_interval</tt>.
  def self.record_counts timestamp=Time.now, &block
   c = Counter.new
   yield(c)
   
   self.transaction do
     check_sample_valid(timestamp)
     
     q = "INSERT INTO #{self.table_name} (sample_time, category, count) VALUES "
     c.counts.each { |key, count| q += self.sanitize_sql(['(?, ?, ?),', timestamp, key, count]) }
     q.chop!
     
     self.connection.execute(q)
     self.delete_all(['sample_time < ?', (timestamp - history_to_keep)])
   end
    
    true
  end
  
  # Returns totals across entire history.  Optional limit param restricts resultset.
  def self.totals limit=nil
    values = self.connection.select_rows("SELECT category, SUM(count) AS cnt FROM #{self.table_name} GROUP BY category ORDER BY cnt DESC #{"LIMIT #{limit}" if limit};")
    values.map { |v| v[1] = v[1].to_i }
    return values
  end
  
  private
  def self.check_sample_valid timestamp
    latest_sample =  self.maximum(:sample_time)
    return if latest_sample.nil? # sample is of course valid if no data exists
    
    distance = (timestamp - latest_sample).abs
    if distance < sample_interval
      raise "Data recorded at #{self.maximum(:sample_time)} making #{timestamp} #{'%0.2f' % (sample_interval - distance)}s too soon on a #{sample_interval} interval."
    end
  end
  
end