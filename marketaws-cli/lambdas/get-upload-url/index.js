const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");

const s3Client = new S3Client({ region: process.env.AWS_REGION });

exports.handler = async (event) => {
    const bucketName = process.env.BUCKET_NAME;
    const fileName = event.queryStringParameters?.file || `prod_${Date.now()}.jpg`;
    const contentType = event.queryStringParameters?.type || 'image/jpeg';

    const command = new PutObjectCommand({
        Bucket: bucketName,
        Key: `uploads/${fileName}`,
        ContentType: contentType
    });

    try {
        const uploadUrl = await getSignedUrl(s3Client, command, { expiresIn: 300 });
        return {
            statusCode: 200,
            headers: {
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/json"
            },
            body: JSON.stringify({ uploadUrl, key: `uploads/${fileName}` })
        };
    } catch (err) {
        return {
            statusCode: 500,
            body: JSON.stringify({ error: err.message })
        };
    }
};
