require File.dirname(__FILE__) + '/test_helper'

class Resque::DelayedQueueTest < Test::Unit::TestCase

  def setup
    Resque::Scheduler.mute = true
    Resque.flushall
  end

  def test_enqueue_at_adds_correct_list

    timestamp = Time.now - 1 # 1 second ago (in the past, should come out right away)

    assert_equal(0, Resque.delayed_queue.count, "delayed queue should be empty to start")

    assert_equal 1, Resque.enqueue_at(timestamp, SomeIvarJob, "path")

    # Confirm the correct keys were added
    assert_equal(1, Resque.delayed_queue.find_one('_id' => timestamp.to_i)['items'].size, "delayed queue should have one entry now")
    assert_equal(1, Resque.delayed_queue_schedule_size, "The delayed_queue_schedule should have 1 entry now")

    read_timestamp = Resque.next_delayed_timestamp

    # Confirm the timestamp came out correctly
    assert_equal(timestamp.to_i, read_timestamp, "The timestamp we pull out of redis should match the one we put in")
    item = Resque.next_item_for_timestamp(read_timestamp)

    # Confirm the item came out correctly
    assert_equal('SomeIvarJob', item['class'], "Should be the same class that we queued")
    assert_equal(["path"], item['args'], "Should have the same arguments that we queued")
    
    # And now confirm the keys are gone
    assert_equal(0, Resque.delayed_queue.find('_id' => timestamp.to_i).count) # tests +clean_up_timestamp+
    assert_equal(0, Resque.delayed_queue_schedule_size, "delayed queue should be empty")
  end

  def test_something_in_the_future_doesnt_come_out
    timestamp = Time.now + 600 # 10 minutes from now (in the future, shouldn't come out)

    assert_equal(0, Resque.delayed_queue.find('_id' => timestamp.to_i).count, "delayed queue should be empty to start")

    assert_equal 1, Resque.enqueue_at(timestamp, SomeIvarJob, "path")

    # Confirm the correct keys were added
    assert_equal(1, Resque.delayed_queue.find_one('_id' => timestamp.to_i)['items'].size, "delayed queue should have one entry now")
    assert_equal(1, Resque.delayed_queue_schedule_size, "The delayed_queue_schedule should have 1 entry now")

    read_timestamp = Resque.next_delayed_timestamp

    assert_nil(read_timestamp, "No timestamps should be ready for queueing")
  end

  def test_something_in_the_future_comes_out_if_you_want_it_to
    timestamp = Time.now + 600 # 10 minutes from now

    assert_equal 1, Resque.enqueue_at(timestamp, SomeIvarJob, "path")

    read_timestamp = Resque.next_delayed_timestamp(timestamp)

    assert_equal(timestamp.to_i, read_timestamp, "The timestamp we pull out of redis should match the one we put in")
  end

  def test_enqueue_at_and_enqueue_in_are_equivalent
    timestamp = Time.now + 60

    assert_equal 1, Resque.enqueue_at(timestamp, SomeIvarJob, "path")
    assert_equal 2, Resque.enqueue_in(timestamp - Time.now, SomeIvarJob, "path")

    assert_equal(1, Resque.delayed_queue_schedule_size, "should have one timestamp in the delayed queue")
    assert_equal(2, Resque.delayed_queue.find_one('_id' => timestamp.to_i)['items'].size, "should have 2 items in the timestamp queue")
  end

  def test_empty_delayed_queue_peek
    assert_equal([], Resque.delayed_queue_peek(0,20))
  end

  def test_delayed_queue_peek
    t = Time.now
    expected_timestamps = (1..5).to_a.map do |i|
      (t + 60 + i).to_i
    end

    expected_timestamps.each do |timestamp|
      Resque.delayed_push(timestamp, {:class => SomeIvarJob.to_s, :args => 'blah1'})
    end

    timestamps = Resque.delayed_queue_peek(2,3)

    assert_equal(expected_timestamps[2,3], timestamps)
  end

  def test_delayed_queue_schedule_size
    assert_equal(0, Resque.delayed_queue_schedule_size)
    assert_equal 1, Resque.enqueue_at(Time.now+60, SomeIvarJob)
    assert_equal(1, Resque.delayed_queue_schedule_size)
  end

  def test_delayed_timestamp_size
    t = Time.now + 60
    assert_equal(0, Resque.delayed_timestamp_size(t))
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal(1, Resque.delayed_timestamp_size(t))
    assert_equal(0, Resque.delayed_timestamp_size(t.to_i+1))
  end

  def test_delayed_timestamp_peek
    t = Time.now + 60
    assert_equal([], Resque.delayed_timestamp_peek(t, 0, 1), "make sure it's an empty array, not nil")
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal(1, Resque.delayed_timestamp_peek(t, 0, 1).length)
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal(1, Resque.delayed_timestamp_peek(t, 0, 1).length)
    assert_equal(2, Resque.delayed_timestamp_peek(t, 0, 3).length)

    assert_equal(
      {'args' => [], 'class' => 'SomeIvarJob', 'queue' => 'ivar'},
      Resque.delayed_timestamp_peek(t, 0, 1).first
    )
  end

  def test_handle_delayed_items_with_no_items
    Resque::Scheduler.expects(:enqueue).never
    Resque::Scheduler.handle_delayed_items
  end

  def test_handle_delayed_items_with_items
    t = Time.now - 60 # in the past
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob)

    # 2 SomeIvarJob jobs should be created in the "ivar" queue
    Resque::Job.expects(:create).twice.with('ivar', 'SomeIvarJob', nil)
    Resque.expects(:queue_from_class).never # Should NOT need to load the class
    Resque::Scheduler.handle_delayed_items
  end

  def test_handle_delayed_items_with_items_in_the_future
    t = Time.now + 60 # in the future
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob)

    # 2 SomeIvarJob jobs should be created in the "ivar" queue
    Resque::Job.expects(:create).twice.with('ivar', 'SomeIvarJob', nil)
    Resque.expects(:queue_from_class).never # Should NOT need to load the class
    Resque::Scheduler.handle_delayed_items(t)
  end
  
  def test_enqueue_delayed_items_for_timestamp
    t = Time.now + 60
    
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob)

    # 2 SomeIvarJob jobs should be created in the "ivar" queue
    Resque::Job.expects(:create).twice.with('ivar', 'SomeIvarJob', nil)
    Resque.expects(:queue_from_class).never # Should NOT need to load the class

    Resque::Scheduler.enqueue_delayed_items_for_timestamp(t)
    
    # delayed queue for timestamp should be empty
    assert_equal(0, Resque.delayed_timestamp_peek(t, 0, 3).length)
  end

  def test_works_with_out_specifying_queue__upgrade_case
    t = Time.now - 60
    Resque.delayed_push(t, :class => 'SomeIvarJob')

    # Since we didn't specify :queue when calling delayed_push, it will be forced
    # to load the class to figure out the queue.  This is the upgrade case from 1.0.4
    # to 1.0.5.
    Resque::Job.expects(:create).once.with(:ivar, 'SomeIvarJob', nil)

    Resque::Scheduler.handle_delayed_items
  end

  def test_clearing_delayed_queue
    t = Time.now + 120
    4.times { |i| assert_equal i + 1, Resque.enqueue_at(t, SomeIvarJob) }
    4.times { |i| assert_equal 1, Resque.enqueue_at(Time.now + rand(100), SomeIvarJob) }

    Resque.reset_delayed_queue
    assert_equal(0, Resque.delayed_queue_schedule_size)
  end

  def test_remove_specific_item
    t = Time.now + 120
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob)

    Resque.remove_delayed(SomeIvarJob)
    assert_equal [], Resque.delayed_queue.find_one('_id' => t.to_i)['items']
  end

  def test_remove_bogus_item_leaves_the_rest_alone
    t = Time.now + 120
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob, "foo")
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob, "bar")
    assert_equal 3, Resque.enqueue_at(t, SomeIvarJob, "bar")
    assert_equal 4, Resque.enqueue_at(t, SomeIvarJob, "baz")

    Resque.remove_delayed(SomeIvarJob)
    
    items = Resque.delayed_queue.find_one('_id' => t.to_i)['items']
    assert_equal(4, items.size)
  end

  def test_remove_specific_item_in_group_of_other_items_at_same_timestamp
    t = Time.now + 120
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob, "foo")
    assert_equal 2, Resque.enqueue_at(t, SomeIvarJob, "bar")
    assert_equal 3, Resque.enqueue_at(t, SomeIvarJob, "bar")
    assert_equal 4, Resque.enqueue_at(t, SomeIvarJob, "baz")

    Resque.remove_delayed(SomeIvarJob, "bar")
    
    items = Resque.delayed_queue.find_one('_id' => t.to_i)['items']
    assert_equal(2, items.size)
    assert_equal(1, Resque.delayed_queue_schedule_size)
  end
  
  def test_remove_specific_item_in_group_of_other_items_at_different_timestamps
    t = Time.now + 120
    assert_equal 1, Resque.enqueue_at(t, SomeIvarJob, "foo")
    assert_equal 1, Resque.enqueue_at(t + 1, SomeIvarJob, "bar")
    assert_equal 1, Resque.enqueue_at(t + 2, SomeIvarJob, "bar")
    assert_equal 1, Resque.enqueue_at(t + 3, SomeIvarJob, "baz")

    Resque.remove_delayed(SomeIvarJob, "bar")
    assert_equal(1, Resque.delayed_queue.find_one('_id' => t.to_i)['items'].size)
    assert_equal(0, Resque.delayed_queue.find_one('_id' => t.to_i + 1)['items'].size)
    assert_equal(0, Resque.delayed_queue.find_one('_id' => t.to_i + 2)['items'].size)
    assert_equal(1, Resque.delayed_queue.find_one('_id' => t.to_i + 3)['items'].size)
    assert_equal(2, Resque.count_all_scheduled_jobs)
  end
end
