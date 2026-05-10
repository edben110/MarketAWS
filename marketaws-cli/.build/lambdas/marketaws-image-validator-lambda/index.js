const { S3Client, HeadObjectCommand, CopyObjectCommand, DeleteObjectCommand } = require("@aws-sdk/client-s3");
const { RekognitionClient, DetectModerationLabelsCommand } = require("@aws-sdk/client-rekognition");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");

const s3 = new S3Client({});
const rekognition = new RekognitionClient({});
const sns = new SNSClient({});

const MAX_SIZE = 5 * 1024 * 1024;
const ALLOWED_TYPES = new Set(['image/jpeg', 'image/png']);

exports.handler = async (event) => {
  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));

    if (!key.startsWith('uploads/')) {
      continue;
    }

    try {
      const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));

      if (head.ContentLength > MAX_SIZE || !ALLOWED_TYPES.has(head.ContentType)) {
        await rejectFile(bucket, key, 'Invalid size or format');
        continue;
      }

      const moderation = await rekognition.send(new DetectModerationLabelsCommand({
        Image: { S3Object: { Bucket: bucket, Name: key } },
        MinConfidence: 60
      }));

      if (moderation.ModerationLabels && moderation.ModerationLabels.length > 0) {
        await rejectFile(bucket, key, 'Explicit content detected');
        continue;
      }

      console.log(`Image accepted: ${key}`);
    } catch (err) {
      console.error(`Error processing ${key}:`, err);
    }
  }

  return { ok: true };
};

async function rejectFile(bucket, key, reason) {
  const fileName = key.split('/').pop();
  const rejectedKey = `rejected/${fileName}`;

  await s3.send(new CopyObjectCommand({
    Bucket: bucket,
    CopySource: `${bucket}/${encodeURIComponent(key)}`,
    Key: rejectedKey
  }));

  await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));

  await sns.send(new PublishCommand({
    TopicArn: process.env.SNS_TOPIC_ARN,
    Message: JSON.stringify({
      type: 'image.rejected',
      bucket,
      key: rejectedKey,
      reason
    }),
    MessageAttributes: {
      eventType: { DataType: 'String', StringValue: 'image.rejected' },
      destination: { DataType: 'String', StringValue: 'seller-notifications-queue' }
    }
  }));
}
